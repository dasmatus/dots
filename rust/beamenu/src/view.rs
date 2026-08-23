//! The view layer: a safe wrapper over the patched `libbemenu`.
//!
//! bemenu's event loop belongs to its client, not to the library. `run_menu()`
//! in `client/common/common.c` is a `do { render; poll_key } while (
//! run_with_events(...) == RUNNING)` loop, and every call returns after a
//! single keystroke. That is what lets beamenu be the client: this module
//! reimplements that loop in Rust and repopulates the item list between
//! iterations, which is the whole mechanism behind dynamic results.
//!
//! Pointer and touch input are not wired. `bm_menu_run_with_events` takes
//! `struct bm_pointer` and `struct bm_touch` by value, and reproducing their
//! layouts across the FFI to support mouse input in a launcher driven entirely
//! from the keyboard is not worth the fragility. [`Menu::pump`] calls
//! `bm_menu_run_with_key` instead, which is the same path minus those two.

use std::ffi::{c_char, c_int, c_uint, c_void, CStr, CString};
use std::ptr;

use anyhow::{anyhow, Result};

use crate::config::Config;
use crate::item::Item;

#[repr(C)]
pub struct BmMenu {
    _private: [u8; 0],
}

#[repr(C)]
pub struct BmItem {
    _private: [u8; 0],
}

// Enum discriminants, transcribed from lib/bemenu.h.
//
// These are hand-written rather than bindgen-generated because the crate binds
// about thirty functions and four enums, and a build-time bindgen would drag a
// libclang dependency into every Nix build of this package for that. The cost
// is that a bemenu version bump can silently renumber them: bemenu only ever
// appends to these enums, and the beamenu patch series adds exactly one
// variant (BM_FILTER_MODE_NONE, inserted before the LAST sentinel), so each
// value below was checked against the patched header rather than assumed.
//
// Verified against bemenu 0.6.23 plus nix/patches/beamenu.

/// Passed to [`Menu::set_pills`] as the active index to mean no pill is
/// filtering; mirrors `BM_PILL_NONE` in `lib/bemenu.h`.
///
/// The bar still draws. The capsule naming the highlighted row's section takes
/// the active fill instead of its outline, since no chosen capsule is left to
/// confuse it with, which is what the bar should say while a search spans
/// every section.
pub const BM_PILL_NONE: u32 = u32::MAX;

// enum bm_filter_mode
const BM_FILTER_MODE_NONE: c_int = 2;

// enum bm_align
const BM_ALIGN_CENTER: c_int = 2;

// enum bm_key, the subset this loop reacts to.
const BM_KEY_ESCAPE: c_int = 20;
const BM_KEY_SHIFT_RETURN: c_int = 22;
const BM_KEY_CONTROL_RETURN: c_int = 23;

// enum bm_run_result
const BM_RUN_RESULT_RUNNING: c_int = 0;
const BM_RUN_RESULT_SELECTED: c_int = 1;

// enum bm_color
const BM_COLOR_TITLE_BG: c_int = 0;
const BM_COLOR_TITLE_FG: c_int = 1;
const BM_COLOR_FILTER_BG: c_int = 2;
const BM_COLOR_FILTER_FG: c_int = 3;
const BM_COLOR_CURSOR_BG: c_int = 4;
const BM_COLOR_CURSOR_FG: c_int = 5;
const BM_COLOR_ITEM_BG: c_int = 6;
const BM_COLOR_ITEM_FG: c_int = 7;
const BM_COLOR_HIGHLIGHTED_BG: c_int = 8;
const BM_COLOR_HIGHLIGHTED_FG: c_int = 9;
const BM_COLOR_SELECTED_BG: c_int = 12;
const BM_COLOR_SELECTED_FG: c_int = 13;
const BM_COLOR_ALTERNATE_BG: c_int = 14;
const BM_COLOR_ALTERNATE_FG: c_int = 15;
const BM_COLOR_BORDER: c_int = 18;

#[link(name = "bemenu")]
extern "C" {
    fn bm_init() -> bool;

    fn bm_menu_new(renderer: *const c_char) -> *mut BmMenu;
    fn bm_menu_free(menu: *mut BmMenu);
    fn bm_menu_free_items(menu: *mut BmMenu);

    fn bm_menu_set_filter_mode(menu: *mut BmMenu, mode: c_int);
    fn bm_menu_set_lines(menu: *mut BmMenu, lines: c_uint);
    fn bm_menu_set_align(menu: *mut BmMenu, align: c_int);
    fn bm_menu_set_width(menu: *mut BmMenu, margin: c_uint, factor: f32);
    fn bm_menu_set_border_size(menu: *mut BmMenu, size: f64);
    fn bm_menu_set_border_radius(menu: *mut BmMenu, radius: f64);
    fn bm_menu_set_fixed_height(menu: *mut BmMenu, mode: bool);
    fn bm_menu_set_line_height(menu: *mut BmMenu, height: c_uint);
    fn bm_menu_set_title(menu: *mut BmMenu, title: *const c_char) -> bool;
    fn bm_menu_set_font(menu: *mut BmMenu, font: *const c_char) -> bool;
    fn bm_menu_set_color(menu: *mut BmMenu, color: c_int, hex: *const c_char) -> bool;
    fn bm_menu_grab_keyboard(menu: *mut BmMenu, grab: bool);
    fn bm_menu_set_filter(menu: *mut BmMenu, filter: *const c_char);
    fn bm_menu_get_filter(menu: *mut BmMenu) -> *const c_char;
    fn bm_menu_set_highlighted_index(menu: *mut BmMenu, index: c_uint) -> bool;
    fn bm_menu_get_highlighted_item(menu: *mut BmMenu) -> *mut BmItem;
    fn bm_menu_add_item(menu: *mut BmMenu, item: *mut BmItem) -> bool;
    fn bm_menu_render(menu: *mut BmMenu) -> bool;
    fn bm_menu_poll_key(menu: *mut BmMenu, unicode: *mut c_uint) -> c_int;
    fn bm_menu_run_with_key(menu: *mut BmMenu, key: c_int, unicode: c_uint) -> c_int;

    // Added by nix/patches/beamenu.
    fn bm_menu_set_rich_rows(menu: *mut BmMenu, rich: bool);
    fn bm_menu_set_icon_size(menu: *mut BmMenu, size: c_uint);
    fn bm_menu_set_search_height(menu: *mut BmMenu, height: c_uint);
    fn bm_menu_set_pills(menu: *mut BmMenu, spec: *const c_char, active: c_uint);
    fn bm_menu_get_active_pill(menu: *mut BmMenu) -> c_uint;

    fn bm_item_new(text: *const c_char) -> *mut BmItem;
    fn bm_item_set_subtitle(item: *mut BmItem, text: *const c_char) -> bool;
    fn bm_item_set_accessory(item: *mut BmItem, text: *const c_char) -> bool;
    fn bm_item_set_icon(item: *mut BmItem, text: *const c_char) -> bool;
    fn bm_item_set_section(item: *mut BmItem, text: *const c_char) -> bool;
    fn bm_item_set_userdata(item: *mut BmItem, userdata: *mut c_void);
    fn bm_item_get_userdata(item: *mut BmItem) -> *mut c_void;
}

/// What one turn of the loop produced.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// Still running; `query` is the current search text.
    Running { query: String },
    /// Enter on the item at this index into the list last handed to
    /// [`Menu::set_items`].
    Selected { index: usize },
    /// Ctrl+Enter, which beamenu binds to the alternate-action panel.
    Alternate { index: usize },
    /// Escape, or the compositor closing the surface.
    Cancelled,
}

/// A live bemenu instance.
///
/// Deliberately neither `Send` nor `Sync`, which the raw pointer field already
/// enforces. libbemenu keeps its renderer registry and the renderer keeps its
/// Wayland connection in unsynchronised globals, so a menu belongs to the
/// thread that created it. Nothing in beamenu wants to move one; this note is
/// here so nobody adds an `unsafe impl Send` to make a borrow checker error go
/// away.
pub struct Menu {
    ptr: *mut BmMenu,
    /// Number of items currently in the menu, so an index read back out of
    /// item userdata can be bounds-checked before safe code sees it.
    len: usize,
}

fn cstr(value: &str) -> CString {
    // Interior NULs cannot reach C. Truncating at the first one keeps a
    // pathological title from taking the launcher down.
    CString::new(value).unwrap_or_else(|err| {
        let bytes = err.into_vec();
        let cut = bytes.iter().position(|b| *b == 0).unwrap_or(bytes.len());
        CString::new(&bytes[..cut]).expect("truncated at the first NUL")
    })
}

impl Menu {
    /// Open a menu on the auto-detected renderer.
    ///
    /// # Errors
    /// Fails when no renderer can be activated, which in practice means there
    /// is no Wayland or X11 display to draw on.
    pub fn new(config: &Config) -> Result<Self> {
        // bm_init dlopens the renderer plugins into a `static struct list`
        // guarded by nothing. It self-checks for a non-empty list and so is
        // idempotent on one thread, but two threads racing the first call
        // would both find it empty and both populate it. Once makes that
        // impossible without relying on a detail of the C side.
        static INIT: std::sync::Once = std::sync::Once::new();
        static mut INIT_OK: bool = false;

        INIT.call_once(|| {
            // SAFETY: runs exactly once, before any menu exists, and writes
            // INIT_OK while no other thread can observe it.
            unsafe { INIT_OK = bm_init() };
        });

        // SAFETY: INIT.call_once has returned, so the write above happened-
        // before this read and no further write can occur.
        if !unsafe { INIT_OK } {
            return Err(anyhow!(
                "bm_init found no bemenu renderers; is BEMENU_RENDERERS pointing at beamenu-view's lib/bemenu?"
            ));
        }

        // SAFETY: a NULL renderer name asks bemenu to auto-detect.
        let ptr = unsafe { bm_menu_new(ptr::null()) };
        if ptr.is_null() {
            return Err(anyhow!(
                "bm_menu_new failed: no usable renderer (is a Wayland display running?)"
            ));
        }

        let menu = Self { ptr, len: 0 };
        menu.apply(config);
        Ok(menu)
    }

    fn apply(&self, config: &Config) {
        let theme = &config.theme;
        let colors = [
            (BM_COLOR_TITLE_BG, &theme.background),
            (BM_COLOR_TITLE_FG, &theme.heading),
            (BM_COLOR_FILTER_BG, &theme.background),
            (BM_COLOR_FILTER_FG, &theme.foreground),
            (BM_COLOR_CURSOR_BG, &theme.background),
            (BM_COLOR_CURSOR_FG, &theme.foreground),
            (BM_COLOR_ITEM_BG, &theme.background),
            (BM_COLOR_ITEM_FG, &theme.foreground),
            // The pill bar's active capsule and the highlighted list row
            // share this pair (patch 06), so the accent used for one is the
            // accent used for both; the foreground half is left on
            // selected_foreground, unchanged from before this field existed.
            (BM_COLOR_HIGHLIGHTED_BG, &theme.accent),
            (BM_COLOR_HIGHLIGHTED_FG, &theme.selected_foreground),
            (BM_COLOR_SELECTED_BG, &theme.selected_background),
            (BM_COLOR_SELECTED_FG, &theme.selected_foreground),
            // The alternate pair is what the rich row renderer draws
            // subtitles and accessories in, not a zebra stripe.
            (BM_COLOR_ALTERNATE_BG, &theme.background),
            (BM_COLOR_ALTERNATE_FG, &theme.muted),
            (BM_COLOR_BORDER, &theme.border),
        ];

        // SAFETY: every pointer below is a live CString for the duration of
        // its call, and self.ptr is non-null for the lifetime of this Menu.
        unsafe {
            for (slot, hex) in colors {
                let hex = cstr(hex);
                bm_menu_set_color(self.ptr, slot, hex.as_ptr());
            }
            let font = cstr(&theme.font);
            bm_menu_set_font(self.ptr, font.as_ptr());
            let title = cstr("Search");
            bm_menu_set_title(self.ptr, title.as_ptr());

            bm_menu_set_filter_mode(self.ptr, BM_FILTER_MODE_NONE);
            bm_menu_set_lines(self.ptr, config.lines);
            bm_menu_set_align(self.ptr, BM_ALIGN_CENTER);
            bm_menu_set_width(self.ptr, 0, config.width_factor);
            bm_menu_set_border_size(self.ptr, 1.0);
            bm_menu_set_border_radius(self.ptr, f64::from(config.radius));
            // Fixed height keeps the panel from resizing on every keystroke,
            // which is the difference between a launcher and a jitter machine.
            bm_menu_set_fixed_height(self.ptr, true);
            bm_menu_set_line_height(self.ptr, config.line_height);

            bm_menu_set_rich_rows(self.ptr, true);
            bm_menu_set_icon_size(self.ptr, config.icon_size);
            bm_menu_set_search_height(self.ptr, config.search_height);

            bm_menu_grab_keyboard(self.ptr, true);
        }
    }

    /// Replace the menu's contents.
    ///
    /// The index of each item is stashed in its userdata, so the highlighted
    /// row can be mapped back to `items` without keeping raw pointers around
    /// on the Rust side.
    pub fn set_items(&mut self, items: &[Item]) {
        // SAFETY: free_items drops every item the menu owns. The patched
        // library no longer frees filter_item here, so this is safe to call
        // repeatedly; on stock bemenu it would dangle.
        unsafe { bm_menu_free_items(self.ptr) };
        self.len = 0;

        for (index, item) in items.iter().enumerate() {
            // SAFETY: bm_item_new copies the text; on success bm_menu_add_item
            // takes ownership and the menu frees it in free_items.
            unsafe {
                let title = cstr(&item.title);
                let raw = bm_item_new(title.as_ptr());
                if raw.is_null() {
                    continue;
                }
                if let Some(subtitle) = &item.subtitle {
                    let value = cstr(subtitle);
                    bm_item_set_subtitle(raw, value.as_ptr());
                }
                if let Some(accessory) = &item.accessory {
                    let value = cstr(accessory);
                    bm_item_set_accessory(raw, value.as_ptr());
                }
                if let Some(icon) = &item.icon {
                    let value = cstr(&icon.to_string_lossy());
                    bm_item_set_icon(raw, value.as_ptr());
                }
                if let Some(section) = &item.section {
                    let value = cstr(section);
                    bm_item_set_section(raw, value.as_ptr());
                }
                bm_item_set_userdata(raw, index as *mut c_void);

                if bm_menu_add_item(self.ptr, raw) {
                    self.len += 1;
                }
            }
        }

        // A refilled list is a different list; keeping the old highlight would
        // point at whatever now happens to sit at that offset.
        // SAFETY: index 0 is clamped internally when the list is empty.
        unsafe { bm_menu_set_highlighted_index(self.ptr, 0) };
    }

    /// The current search text.
    #[must_use]
    pub fn query(&self) -> String {
        // SAFETY: the returned pointer is owned by the menu and valid until
        // the filter changes; it is copied out before returning.
        unsafe {
            let raw = bm_menu_get_filter(self.ptr);
            if raw.is_null() {
                String::new()
            } else {
                CStr::from_ptr(raw).to_string_lossy().into_owned()
            }
        }
    }

    /// Overwrite the search text, for example when popping a frame.
    pub fn set_query(&mut self, query: &str) {
        // SAFETY: bm_menu_set_filter copies the string.
        let query = cstr(query);
        unsafe { bm_menu_set_filter(self.ptr, query.as_ptr()) };
    }

    /// Set the filter pill bar, drawn between the search row and the list.
    ///
    /// `spec` is `\x1f`-separated `label:count` entries; empty clears the
    /// bar. `active` is the pill to mark active, clamped to the last entry
    /// by the C side when out of range.
    pub fn set_pills(&self, spec: &str, active: u32) {
        // SAFETY: bm_menu_set_pills copies spec for the duration of the
        // call; self.ptr is non-null for the lifetime of this Menu.
        let spec = cstr(spec);
        unsafe { bm_menu_set_pills(self.ptr, spec.as_ptr(), active) };
    }

    /// Index of the active pill, last moved by Tab/Shift+Tab in rich mode.
    #[must_use]
    pub fn active_pill(&self) -> u32 {
        // SAFETY: self.ptr is non-null for the lifetime of this Menu.
        unsafe { bm_menu_get_active_pill(self.ptr) }
    }

    /// Index of the highlighted row, read back out of its userdata.
    fn highlighted(&self) -> Option<usize> {
        // SAFETY: the returned item is owned by the menu; only its userdata
        // is read, which set_items wrote as a plain integer.
        unsafe {
            let item = bm_menu_get_highlighted_item(self.ptr);
            if item.is_null() {
                return None;
            }
            let index = bm_item_get_userdata(item) as usize;
            (index < self.len).then_some(index)
        }
    }

    /// Draw a frame, wait for one key, and act on it.
    ///
    /// This is `run_menu`'s body: render, block in the renderer's `epoll_wait`
    /// until something happens, then feed the key back into the state machine.
    pub fn pump(&mut self) -> Outcome {
        // SAFETY: render returns false when the surface is gone, which is the
        // compositor's way of saying the menu was dismissed.
        if !unsafe { bm_menu_render(self.ptr) } {
            return Outcome::Cancelled;
        }

        let mut unicode: c_uint = 0;
        // SAFETY: unicode is a live out-parameter for the call's duration.
        let key = unsafe { bm_menu_poll_key(self.ptr, &raw mut unicode) };

        // Ctrl+Enter opens the alternate-action panel. It is read before
        // run_with_key because the library maps it to a plain selection.
        let alternate = key == BM_KEY_CONTROL_RETURN || key == BM_KEY_SHIFT_RETURN;
        let escape = key == BM_KEY_ESCAPE;

        // SAFETY: advances the menu's own state machine by one key.
        let status = unsafe { bm_menu_run_with_key(self.ptr, key, unicode) };

        if escape {
            return Outcome::Cancelled;
        }

        match status {
            BM_RUN_RESULT_SELECTED => match self.highlighted() {
                Some(index) if alternate => Outcome::Alternate { index },
                Some(index) => Outcome::Selected { index },
                // Enter on an empty list is not a selection, just a no-op.
                None => Outcome::Running {
                    query: self.query(),
                },
            },
            BM_RUN_RESULT_RUNNING => Outcome::Running {
                query: self.query(),
            },
            // BM_RUN_RESULT_CANCEL, plus every CUSTOM_n binding beamenu
            // defines and beamenu does not use: dismiss rather than guess.
            _ => Outcome::Cancelled,
        }
    }
}

impl Drop for Menu {
    fn drop(&mut self) {
        // SAFETY: ptr came from bm_menu_new and is freed exactly once.
        unsafe { bm_menu_free(self.ptr) };
    }
}
