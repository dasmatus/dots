//! The static HTML/JS page every canvas window loads exactly once via
//! `load_html`, plus the pure builders for the `evaluate_javascript` calls
//! that drive it afterwards.
//!
//! The page itself carries no design tokens — those arrive separately as a
//! WebKit user stylesheet (`crate::theme::stylesheet`), injected once at
//! startup via `WebKitUserContentManager` rather than baked into this
//! markup, so the one host-enforced stylesheet applies regardless of what
//! this shell renders. This file only ever receives *data* from workers
//! (component JSON, log text), passed through [`serde_json`] string
//! escaping before landing in a `<script>` call — never worker-authored
//! markup.

/// The page loaded once at startup. Defines `window.__beamenu`, the small
/// bridge the Rust side calls into via `evaluate_javascript`, and posts back
/// through the `formSubmit` script message handler on submit.
pub const PAGE_SHELL: &str = r#"<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:;">
</head>
<body>
<div id="root" class="panel"><div id="content"></div></div>
<script>
window.__beamenu = {
  renderDetail(html) {
    document.getElementById('content').innerHTML = '<div class="detail">' + html + '</div>';
  },
  renderLog() {
    document.getElementById('content').innerHTML =
      '<pre id="log" class="log"></pre>' +
      '<details id="stderr-strip"><summary class="muted">stderr</summary><pre id="stderr" class="log"></pre></details>' +
      '<div id="exit-status" class="muted"></div>';
  },
  appendLog(html) {
    const log = document.getElementById('log');
    if (!log) return;
    log.innerHTML += html;
    log.scrollTop = log.scrollHeight;
  },
  appendStderr(html) {
    const stderr = document.getElementById('stderr');
    if (!stderr) return;
    stderr.innerHTML += html;
  },
  showExit(text) {
    const status = document.getElementById('exit-status');
    if (status) status.textContent = text;
  },
  renderForm(fields, submitLabel) {
    const content = document.getElementById('content');
    content.innerHTML = '';
    const form = document.createElement('form');
    const values = {};
    for (const field of fields) {
      const row = document.createElement('div');
      row.className = 'field';
      const label = document.createElement('label');
      label.textContent = field.label;
      row.appendChild(label);
      let input;
      if (field.type === 'dropdown') {
        input = document.createElement('select');
        for (const opt of (field.options || [])) {
          const o = document.createElement('option');
          o.value = opt;
          o.textContent = opt;
          input.appendChild(o);
        }
        if (field.value !== undefined && field.value !== null) input.value = field.value;
      } else if (field.type === 'checkbox') {
        input = document.createElement('input');
        input.type = 'checkbox';
        input.checked = Boolean(field.value);
      } else {
        input = document.createElement('input');
        input.type = field.type === 'password' ? 'password' : 'text';
        if (field.value !== undefined && field.value !== null) input.value = field.value;
      }
      input.addEventListener('input', () => {
        values[field.key] = field.type === 'checkbox' ? input.checked : input.value;
      });
      values[field.key] = field.type === 'checkbox' ? Boolean(field.value) : (field.value ?? '');
      row.appendChild(input);
      form.appendChild(row);
    }
    const submit = document.createElement('button');
    submit.type = 'submit';
    submit.className = 'primary';
    submit.textContent = submitLabel || 'Submit';
    form.appendChild(submit);
    form.addEventListener('submit', (event) => {
      event.preventDefault();
      window.webkit.messageHandlers.formSubmit.postMessage(JSON.stringify(values));
    });
    content.appendChild(form);
  },
};
</script>
</body>
</html>"#;

/// The page a `--preview` pane loads once at startup.
///
/// Sized to the whole launcher panel rather than to the preview column, and
/// transparent everywhere outside it. Both surfaces are unanchored layer
/// surfaces the compositor centres, so two of the same size land on top of
/// each other and the pane needs no idea where on the output that was. What
/// it does need is where the column sits inside the panel, which is what
/// `place` is told.
///
/// The column is a flex column: the preview scrolls, the metadata strip is
/// pinned under it, and a row with no metadata gives that height back rather
/// than reserving an empty strip.
pub const PREVIEW_SHELL: &str = r#"<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; frame-src 'self';">
<style>
html, body { background: transparent; overflow: hidden; }
#column {
  position: absolute;
  display: none;
  flex-direction: column;
  overflow: hidden;
}
#column.visible { display: flex; }
</style>
</head>
<body>
<div id="column">
  <div id="head" class="preview-head"></div>
  <div id="body" class="preview-body"></div>
  <div id="meta"></div>
</div>
<script>
window.__pane = {
  place(left, top, width, height) {
    const column = document.getElementById('column');
    column.style.left = left + 'px';
    column.style.top = top + 'px';
    column.style.width = width + 'px';
    column.style.height = height + 'px';
  },
  show(title, subtitle, bodyHtml, metaHtml) {
    const head = document.getElementById('head');
    head.textContent = '';
    const name = document.createElement('div');
    name.className = 'preview-title';
    name.textContent = title;
    head.appendChild(name);
    if (subtitle) {
      const sub = document.createElement('div');
      sub.className = 'preview-subtitle muted';
      sub.textContent = subtitle;
      head.appendChild(sub);
    }
    const body = document.getElementById('body');
    body.innerHTML = bodyHtml;
    body.scrollTop = 0;
    document.getElementById('meta').innerHTML = metaHtml;
    document.getElementById('column').classList.add('visible');
  },
  setBody(bodyHtml) {
    document.getElementById('body').innerHTML = bodyHtml;
  },
  hide() {
    document.getElementById('column').classList.remove('visible');
    document.getElementById('body').innerHTML = '';
    document.getElementById('meta').innerHTML = '';
  },
};
</script>
</body>
</html>"#;

/// The `evaluate_javascript` call that moves the column onto the panel's
/// reserved strip.
#[must_use]
pub fn call_place(left: u32, top: u32, width: u32, height: u32) -> String {
    format!("window.__pane.place({left}, {top}, {width}, {height})")
}

/// The `evaluate_javascript` call that draws one row's preview.
///
/// `body_html` and `meta_html` are canvas-generated markup from
/// `crate::preview`; `title` and `subtitle` cross as strings and the page
/// assigns them through `textContent`, never `innerHTML`, so a file named
/// `<script>` is a filename rather than a script.
#[must_use]
pub fn call_show_preview(
    title: &str,
    subtitle: Option<&str>,
    body_html: &str,
    meta_html: &str,
) -> String {
    format!(
        "window.__pane.show({}, {}, {}, {})",
        js_string(title),
        subtitle.map_or_else(|| "null".to_string(), js_string),
        js_string(body_html),
        js_string(meta_html),
    )
}

/// The `evaluate_javascript` call that replaces only the preview body,
/// leaving the title and the metadata strip where they are.
///
/// For a preview that arrives in pieces: a plugin command's output grows as
/// the command runs, and redrawing the whole pane per chunk would reset the
/// scroll position and flicker the heading of a row that has not changed.
#[must_use]
pub fn call_show_preview_body(body_html: &str) -> String {
    format!("window.__pane.setBody({})", js_string(body_html))
}

/// The `evaluate_javascript` call that takes the column off screen.
#[must_use]
pub fn call_hide_preview() -> String {
    "window.__pane.hide()".to_string()
}

/// Name of the `WebKitUserContentManager` script message handler the form
/// submit button posts to.
pub const FORM_SUBMIT_HANDLER: &str = "formSubmit";

fn js_string(text: &str) -> String {
    serde_json::to_string(text).unwrap_or_else(|_| "\"\"".to_string())
}

/// The `evaluate_javascript` call that shows a `detail` component. `html`
/// must already be the canvas-generated, escaped markup from
/// [`crate::markdown::render`] — never worker-supplied text directly.
#[must_use]
pub fn call_render_detail(html: &str) -> String {
    format!("window.__beamenu.renderDetail({})", js_string(html))
}

/// The `evaluate_javascript` call that switches the pane to an empty log.
#[must_use]
pub fn call_render_log() -> String {
    "window.__beamenu.renderLog()".to_string()
}

/// The `evaluate_javascript` call that appends one chunk of canvas-rendered
/// log HTML (from [`crate::ansi::to_html`]) to the log pane.
#[must_use]
pub fn call_append_log(html: &str) -> String {
    format!("window.__beamenu.appendLog({})", js_string(html))
}

/// The `evaluate_javascript` call that appends one chunk of canvas-rendered
/// HTML to the collapsed stderr strip below the log pane.
#[must_use]
pub fn call_append_stderr(html: &str) -> String {
    format!("window.__beamenu.appendStderr({})", js_string(html))
}

/// The `evaluate_javascript` call that shows the exited child's status.
#[must_use]
pub fn call_show_exit(text: &str) -> String {
    format!("window.__beamenu.showExit({})", js_string(text))
}

/// The `evaluate_javascript` call that renders a `form` component.
/// `fields_json` is the `serde_json::to_string` of the validated
/// `Vec<FormField>` — already-typed data, not worker-authored markup.
#[must_use]
pub fn call_render_form(fields_json: &str, submit_label: Option<&str>) -> String {
    let label = submit_label.map_or_else(|| "null".to_string(), js_string);
    format!("window.__beamenu.renderForm({fields_json}, {label})")
}
