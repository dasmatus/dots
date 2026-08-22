//! GTK4 + `gtk4-layer-shell` + WebKitGTK glue: the one place this crate
//! touches `gtk4`, `webkit6` and `gtk4-layer-shell`.
//!
//! Builds a centred, overlay-layer surface sized like the beamenu panel,
//! injects the one design-token stylesheet as a WebKit user stylesheet, and
//! loads `beamenu_canvas::shell::PAGE_SHELL` once. Nothing here is unit
//! tested — the pure model in `beamenu_canvas` (`src/lib.rs`) is what
//! `tests/` exercises.

use std::collections::HashMap;

use gtk4::glib;
use gtk4::prelude::*;
use gtk4_layer_shell::{Edge, KeyboardMode, Layer, LayerShell};
use webkit6::prelude::*;

use beamenu_canvas::shell::{FORM_SUBMIT_HANDLER, PAGE_SHELL};
use beamenu_canvas::theme::CanvasTheme;

/// A built canvas window: the layer-shell `ApplicationWindow` and the
/// `WebView` inside it.
pub struct Canvas {
    pub window: gtk4::ApplicationWindow,
    pub webview: webkit6::WebView,
}

impl Canvas {
    /// Build the window: layer-shell surface (overlay, keyboard EXCLUSIVE,
    /// centred, namespaced `beamenu-canvas`, sized from `width_factor`), a
    /// `WebView` with the design stylesheet injected and navigation away
    /// from the loaded page blocked, and the initial page load.
    #[must_use]
    pub fn build(app: &gtk4::Application, theme: &CanvasTheme, width_factor: f32) -> Self {
        let window = gtk4::ApplicationWindow::builder()
            .application(app)
            .title("beamenu-canvas")
            .build();

        window.init_layer_shell();
        window.set_layer(Layer::Overlay);
        window.set_namespace(Some("beamenu-canvas"));
        window.set_keyboard_mode(KeyboardMode::Exclusive);
        // No anchors: an unanchored layer surface is centred by the
        // compositor, matching how beamenu itself is positioned.
        for edge in [Edge::Left, Edge::Right, Edge::Top, Edge::Bottom] {
            window.set_anchor(edge, false);
        }

        let (width, height) = panel_size(width_factor);
        window.set_default_size(width, height);

        let content_manager = webkit6::UserContentManager::new();
        let sheet = webkit6::UserStyleSheet::new(
            &beamenu_canvas::theme::stylesheet(theme),
            webkit6::UserContentInjectedFrames::AllFrames,
            webkit6::UserStyleLevel::User,
            &[],
            &[],
        );
        content_manager.add_style_sheet(&sheet);
        let _ = content_manager.register_script_message_handler(FORM_SUBMIT_HANDLER, None);

        let webview: webkit6::WebView = glib::Object::builder()
            .property("user-content-manager", &content_manager)
            .build();

        // `WebView::settings` is ambiguous between `gtk4::WidgetExt` (GTK's
        // own display settings) and `webkit6::WebViewExt` (this WebView's
        // WebKitSettings) once both preludes are in scope — disambiguate.
        if let Some(settings) = webkit6::prelude::WebViewExt::settings(&webview) {
            settings.set_enable_javascript(true);
            settings.set_javascript_can_open_windows_automatically(false);
            settings.set_enable_developer_extras(false);
        }

        // The canvas loads exactly one document, ever. Anything that would
        // navigate away from it — a link, a redirect, a form GET/POST to a
        // real URL — is the network fetch this crate promises never
        // happens, so it gets refused rather than followed.
        webview.connect_decide_policy(|_webview, decision, decision_type| {
            if matches!(
                decision_type,
                webkit6::PolicyDecisionType::NavigationAction
                    | webkit6::PolicyDecisionType::NewWindowAction
            ) {
                decision.ignore();
                return true;
            }
            false
        });

        window.set_child(Some(&webview));

        let key_controller = gtk4::EventControllerKey::new();
        let window_for_esc = window.clone();
        key_controller.connect_key_pressed(move |_controller, key, _code, _state| {
            if key == gtk4::gdk::Key::Escape {
                window_for_esc.close();
                glib::Propagation::Stop
            } else {
                glib::Propagation::Proceed
            }
        });
        window.add_controller(key_controller);

        webview.load_html(PAGE_SHELL, None);

        Self { window, webview }
    }

    /// Toggle keyboard interactivity — `NONE` while a `form.submit` request
    /// is in flight so a pkexec/polkit dialog can take focus, `EXCLUSIVE`
    /// once the response lands. Binding behaviour from the task brief.
    pub fn set_keyboard_exclusive(&self, exclusive: bool) {
        self.window.set_keyboard_mode(if exclusive {
            KeyboardMode::Exclusive
        } else {
            KeyboardMode::None
        });
    }

    /// Run one `evaluate_javascript` call against the loaded page, ignoring
    /// the result — every call here is a fire-and-forget DOM update.
    pub fn eval(&self, script: &str) {
        self.webview.evaluate_javascript(
            script,
            None,
            None,
            None::<&gtk4::gio::Cancellable>,
            |_result| {},
        );
    }

    /// Wire the `formSubmit` script message handler: fires `on_submit` with
    /// the parsed `{key: value}` map the page's submit button posted.
    /// Anything that isn't a JSON object of field values is dropped rather
    /// than passed through, matching "workers/pages never hand the host raw
    /// data it didn't ask to validate".
    pub fn on_form_submit(&self, on_submit: impl Fn(HashMap<String, serde_json::Value>) + 'static) {
        let Some(manager) = self.webview.user_content_manager() else {
            return;
        };
        manager.connect_script_message_received(
            Some(FORM_SUBMIT_HANDLER),
            move |_manager, js_value| {
                let raw = js_value.to_str();
                if let Ok(values) = serde_json::from_str::<HashMap<String, serde_json::Value>>(&raw)
                {
                    on_submit(values);
                }
            },
        );
    }
}

fn panel_size(width_factor: f32) -> (i32, i32) {
    // beamenu itself has no absolute width either — `width_factor` is a
    // fraction of a 1920px reference output, the same convention
    // `nix/home/beamenu.nix`'s default (0.375 -> 720px) documents.
    let width = (1920.0 * f64::from(width_factor)).round() as i32;
    let height = ((f64::from(width) * 0.75).round() as i32).max(240);
    (width.max(320), height)
}
