// Arrange.qml's coordinate math and overrides merge, pure and tested
// without a live PanelWindow, MouseArea drag or Hyprland singleton — see
// arrange.js's own header for why the logic lives there rather than in the
// component.
import QtQuick
import QtTest
import "../../nix/home/desktop/quickshell/qml/monitors/arrange.js" as ArrangeLogic

TestCase {
    name: "Arrange"

    function test_fitTransform_centers_and_scales_to_fit() {
        // Two 1920x1080 monitors side by side: a 3840x1080 bounding box into
        // a 720x420 canvas is width-bound (720/3840 < 420/1080), so the
        // scale is that ratio times the 0.9 margin.
        const monitors = [
            { x: 0, y: 0, width: 1920, height: 1080 },
            { x: 1920, y: 0, width: 1920, height: 1080 }
        ];
        const transform = ArrangeLogic.fitTransform(monitors, 720, 420);

        compare(transform.originX, 0);
        compare(transform.originY, 0);
        const expectedScale = Math.min(720 / 3840, 420 / 1080) * 0.9;
        fuzzyCompare(transform.scale, expectedScale, 0.0001);
    }

    function test_fitTransform_is_empty_safe() {
        const transform = ArrangeLogic.fitTransform([], 720, 420);

        compare(transform.originX, 0);
        compare(transform.originY, 0);
        compare(transform.scale, 1);
    }

    // toScreen/toWorldPosition must round-trip: dragging a rectangle to
    // some canvas position and reading it back must return the same real
    // pixel position the monitor was originally placed at, when nothing
    // moved.
    function test_toScreen_and_toWorldPosition_round_trip() {
        const monitors = [
            { x: 0, y: 0, width: 1920, height: 1080 },
            { x: 1920, y: 0, width: 2560, height: 1200 }
        ];
        const transform = ArrangeLogic.fitTransform(monitors, 720, 420);

        for (const m of monitors) {
            const screen = ArrangeLogic.toScreen(m, transform);
            const world = ArrangeLogic.toWorldPosition(screen.x, screen.y, transform);
            compare(world, `${m.x}x${m.y}`);
        }
    }

    function test_closestWithin_data() {
        return [
            { tag: "snaps when within threshold", value: 100, targets: [104], threshold: 10, expected: 104 },
            { tag: "leaves the value when nothing is close enough", value: 100, targets: [200], threshold: 10, expected: 100 },
            { tag: "picks the nearest of several candidates", value: 100, targets: [108, 103], threshold: 10, expected: 103 },
            { tag: "no targets leaves the value alone", value: 100, targets: [], threshold: 10, expected: 100 }
        ];
    }

    function test_closestWithin(row) {
        compare(ArrangeLogic.closestWithin(row.value, row.targets, row.threshold), row.expected);
    }

    // The scenario the feature exists for: two monitors dragged near enough
    // to sit flush snap exactly flush, not a pixel or two off.
    function test_snappedPosition_snaps_a_dragged_edge_to_its_neighbour() {
        const other = { x: 0, y: 0, width: 400, height: 300 };
        const dragged = { x: 405, y: 40, width: 300, height: 200 };

        const snapped = ArrangeLogic.snappedPosition(dragged, [other, dragged], 14);

        compare(snapped.x, 400);
        compare(snapped.y, 40);
    }

    function test_snappedPosition_ignores_itself_in_the_neighbour_list() {
        const solo = { x: 50, y: 60, width: 300, height: 200 };

        const snapped = ArrangeLogic.snappedPosition(solo, [solo], 14);

        compare(snapped.x, 50);
        compare(snapped.y, 60);
    }

    function test_mergedOverrides_data() {
        return [
            {
                tag: "a fresh overrides.json gets one entry per dragged monitor",
                existingRoot: null,
                items: [{ name: "DP-1", position: "0x0" }],
                expected: { entries: [{ name: "DP-1", position: "0x0" }] }
            },
            {
                tag: "a name-matched entry keeps its other fields and only position changes",
                existingRoot: { entries: [{ name: "DP-1", resolution: "1920x1080@240", vrr: "left" }] },
                items: [{ name: "DP-1", position: "1920x0" }],
                expected: { entries: [{ name: "DP-1", resolution: "1920x1080@240", vrr: "left", position: "1920x0" }] }
            },
            {
                tag: "an entry for a monitor absent from the current drag is left alone",
                existingRoot: { entries: [{ name: "DP-9", position: "9999x0" }] },
                items: [{ name: "DP-1", position: "0x0" }],
                expected: { entries: [{ name: "DP-9", position: "9999x0" }, { name: "DP-1", position: "0x0" }] }
            },
            {
                tag: "the edit form's other four fields merge in alongside the dragged position",
                existingRoot: null,
                items: [{ name: "DP-1", position: "500x0", resolution: "2560x1440@120", scale: 1.25, transform: 1, vrr: "left" }],
                expected: { entries: [{ name: "DP-1", position: "500x0", resolution: "2560x1440@120", scale: 1.25, transform: 1, vrr: "left" }] }
            },
            {
                tag: "a field this save's form set joins fields an earlier save already carried",
                existingRoot: { entries: [{ name: "DP-1", resolution: "1920x1080@240", vrr: "left" }] },
                items: [{ name: "DP-1", position: "1920x0", scale: 1.5 }],
                expected: { entries: [{ name: "DP-1", resolution: "1920x1080@240", vrr: "left", position: "1920x0", scale: 1.5 }] }
            },
            {
                // The live path: confirm() sends resolution straight from
                // the Field's text, unlike vrr/transform/scale which go
                // through a parser first — so a monitor whose resolution
                // field the user never typed into really does send "" here,
                // not just the null/undefined case the row above covers.
                tag: "a blank resolution from the form does not clobber an existing override value",
                existingRoot: { entries: [{ name: "DP-1", resolution: "1920x1080@60" }] },
                items: [{ name: "DP-1", position: "0x0", resolution: "" }],
                expected: { entries: [{ name: "DP-1", resolution: "1920x1080@60", position: "0x0" }] }
            },
            {
                // overrides.rs's own doc comment calls this file an ordered
                // list where "first match wins", so touching the middle
                // entry of three must not move it (or anything else) to a
                // different position.
                tag: "existing entries keep their order even when a middle one is touched",
                existingRoot: { entries: [{ name: "DP-9", position: "0x0" }, { name: "DP-1", position: "100x0" }, { name: "DP-5", position: "200x0" }] },
                items: [{ name: "DP-1", position: "999x0" }],
                expected: { entries: [{ name: "DP-9", position: "0x0" }, { name: "DP-1", position: "999x0" }, { name: "DP-5", position: "200x0" }] }
            },
            {
                // A regression guard for the specific hazard of using a
                // plain object as an ordered map: JS iterates any key that
                // looks like an array index (a bare non-negative integer,
                // as a string) in ascending numeric order ahead of every
                // other key, regardless of insertion order — so without
                // order tracked explicitly, "2" and "10" here would jump
                // ahead of "DP-1" and swap places with each other. Hyprland
                // never actually names an output a bare digit, but nothing
                // in this file enforces that.
                tag: "numeric-looking monitor names do not get reordered ahead of string names",
                existingRoot: { entries: [{ name: "10", position: "0x0" }, { name: "DP-1", position: "50x0" }, { name: "2", position: "100x0" }] },
                items: [],
                expected: { entries: [{ name: "10", position: "0x0" }, { name: "DP-1", position: "50x0" }, { name: "2", position: "100x0" }] }
            },
            {
                // description is read-only in the form and never in
                // SETTABLE_FIELDS, so an entry that already carries one
                // must keep it across a save that changes other fields —
                // the merge's copy of the existing entry is what carries
                // it through, not anything item-specific.
                tag: "an existing description survives a save that never touches it",
                existingRoot: { entries: [{ name: "DP-1", description: "Dell U2720Q", resolution: "1920x1080@60" }] },
                items: [{ name: "DP-1", position: "0x0", scale: 1.5 }],
                expected: { entries: [{ name: "DP-1", description: "Dell U2720Q", resolution: "1920x1080@60", position: "0x0", scale: 1.5 }] }
            },
            {
                // A plain {} used as the name-keyed working set has a
                // prototype: "constructor" in {} is true even though
                // nothing was ever assigned to it, which made this entry
                // look like a name already seen and drop it entirely. Only
                // reachable from a hand-edited overrides.json (Hyprland
                // itself never names an output this), same as the
                // numeric-name case above, but the file does not forbid it.
                tag: "an existing entry named after an Object.prototype method survives a save",
                existingRoot: { entries: [{ name: "DP-1", position: "0x0" }, { name: "constructor", position: "77x0", scale: 2 }] },
                items: [],
                expected: { entries: [{ name: "DP-1", position: "0x0" }, { name: "constructor", position: "77x0", scale: 2 }] }
            },
            {
                // description-only entries (no name — overrides.rs's own
                // `name` is optional, and match_override has a documented
                // description-fallback pass) have nothing in `items` that
                // could ever address them, so a save touching its
                // neighbours on both sides must still leave this one
                // exactly where and what it was.
                tag: "a description-only entry survives untouched even when both its neighbours are saved",
                existingRoot: {
                    entries: [
                        { name: "DP-1", position: "0x0" },
                        { description: "VG279QM", resolution: "2560x1440@144" },
                        { name: "HDMI-A-1", position: "2560x0" }
                    ]
                },
                items: [{ name: "DP-1", position: "999x0" }, { name: "HDMI-A-1", position: "3000x0" }],
                expected: {
                    entries: [
                        { name: "DP-1", position: "999x0" },
                        { description: "VG279QM", resolution: "2560x1440@144" },
                        { name: "HDMI-A-1", position: "3000x0" }
                    ]
                }
            },
            {
                // overrides.rs's own doc comment makes the FIRST matching
                // entry the one that governs, and Arrange.qml's own
                // form-loading code (entries.find(...)) likewise reads the
                // first — so on a malformed duplicate-name file, a drag has
                // to land on that first occurrence, not the last. Landing
                // on the last would mean the form shows one entry while the
                // save silently writes onto a different, inert one.
                tag: "a duplicate name resolves to the first occurrence, not the last",
                existingRoot: {
                    entries: [
                        { name: "DP-1", position: "0x0", resolution: "FIRST" },
                        { name: "DP-1", position: "100x0", resolution: "SECOND" }
                    ]
                },
                items: [{ name: "DP-1", position: "999x0" }],
                expected: {
                    entries: [
                        { name: "DP-1", position: "999x0", resolution: "FIRST" },
                        { name: "DP-1", position: "100x0", resolution: "SECOND" }
                    ]
                }
            }
        ];
    }

    function test_mergedOverrides(row) {
        const merged = ArrangeLogic.mergedOverrides(row.existingRoot, row.items);
        compare(merged.entries.length, row.expected.entries.length);
        for (let i = 0; i < row.expected.entries.length; i++) {
            const want = row.expected.entries[i];
            for (const key in want)
                compare(merged.entries[i][key], want[key]);
        }
    }

    // The data-driven case above only checks that the keys it expects carry
    // the right values — it never looks for keys it does not expect, so it
    // cannot prove a field the form left untouched actually stayed absent.
    // hasOwnProperty is what a plain compare() against undefined cannot do:
    // an entry that got `resolution: undefined` written onto it would still
    // read as undefined through a truthiness check, exactly like a field
    // that was never assigned at all.
    function test_mergedOverrides_leaves_untouched_fields_absent() {
        const merged = ArrangeLogic.mergedOverrides(null, [{ name: "DP-1", position: "0x0" }]);
        const entry = merged.entries[0];

        verify(!entry.hasOwnProperty("resolution"));
        verify(!entry.hasOwnProperty("scale"));
        verify(!entry.hasOwnProperty("transform"));
        verify(!entry.hasOwnProperty("vrr"));
    }

    // An empty-string field (a blank form input) must be treated the same
    // as an absent one — applyOverrides in plan.js tests each field with
    // `!= null`, which an empty string passes, so writing "" here would
    // reach hl.monitor as a broken field instead of quietly falling through
    // to the planned spec's own value.
    function test_mergedOverrides_ignores_explicit_empty_strings() {
        const merged = ArrangeLogic.mergedOverrides(null, [{ name: "DP-1", position: "0x0", resolution: "", vrr: "" }]);
        const entry = merged.entries[0];

        verify(!entry.hasOwnProperty("resolution"));
        verify(!entry.hasOwnProperty("vrr"));
    }

    // transform 0 (no rotation) and a zero-ish scale are real, meaningful
    // override values, not "the form left this blank" — the merge must
    // keep them, the same falsy-but-real distinction applyOverrides in
    // plan.js already makes on the read side.
    function test_mergedOverrides_keeps_falsy_but_real_values() {
        const merged = ArrangeLogic.mergedOverrides(null, [{ name: "DP-1", position: "0x0", transform: 0, scale: 1.5 }]);
        const entry = merged.entries[0];

        verify(entry.hasOwnProperty("transform"));
        compare(entry.transform, 0);
        compare(entry.scale, 1.5);
    }

    // overrides.rs types scale as f64 and transform as u8, not a string —
    // a value that merely round-trips through JSON.stringify as the quoted
    // string "1.5" would still satisfy a plain compare() against 1.5, so
    // this checks typeof explicitly, through the same numberField/
    // parseTransform calls Arrange.qml's confirm() actually makes rather
    // than a literal number handed to mergedOverrides directly.
    function test_mergedOverrides_scale_and_transform_stay_numbers_through_the_real_parsers() {
        const merged = ArrangeLogic.mergedOverrides(null, [{
            name: "DP-1",
            position: "0x0",
            scale: ArrangeLogic.numberField("1.5"),
            transform: ArrangeLogic.parseTransform("3")
        }]);
        const entry = merged.entries[0];

        compare(typeof entry.scale, "number");
        compare(typeof entry.transform, "number");
    }

    // A plain {} used as the name-keyed working set would let an item
    // named "toString" (or any other real Object.prototype member) find
    // and silently overwrite that method through the "not found, use the
    // inherited one" fallback a bare `byName[item.name] || {...}` used to
    // have — this is the write-side counterpart to the read-side survival
    // rows above. Checking the real global is what proves the fix actually
    // stops the write, not just that a normal-looking entry comes back.
    function test_mergedOverrides_does_not_pollute_Object_prototype() {
        const before = Object.prototype.toString;

        const merged = ArrangeLogic.mergedOverrides(null, [{ name: "toString", position: "9x9" }]);

        compare(merged.entries.length, 1);
        compare(merged.entries[0].name, "toString");
        compare(merged.entries[0].position, "9x9");
        compare(Object.prototype.toString, before);
        compare(typeof Object.prototype.toString, "function");
    }

    // mergedOverrides copies rather than aliases every entry it reads, so
    // the caller's own existingRoot (Arrange.qml's own overridesRoot,
    // wrapping overridesFile.adapter's declared entries property) must
    // come back exactly as it went in — a merge that mutated its input in
    // place would be indistinguishable from a correct one by this
    // function's own return value alone, so this checks the input
    // separately.
    function test_mergedOverrides_does_not_mutate_its_existingRoot_argument() {
        const existingRoot = { entries: [{ name: "DP-1", position: "0x0", resolution: "1920x1080@60" }] };
        const snapshot = JSON.parse(JSON.stringify(existingRoot));

        ArrangeLogic.mergedOverrides(existingRoot, [{ name: "DP-1", position: "999x0", scale: 1.5 }]);

        compare(JSON.stringify(existingRoot), JSON.stringify(snapshot));
    }

    // The data-driven row above checks the fields a description-only entry
    // is expected to keep, but "for (const key in want)" only checks keys
    // `want` names — it cannot prove `name` stayed absent. hasOwnProperty
    // is what can: this entry's `name` was never set, so it must never
    // silently gain one on the way through the merge.
    function test_mergedOverrides_description_only_entry_never_gains_a_name() {
        const merged = ArrangeLogic.mergedOverrides({ entries: [{ description: "VG279QM", resolution: "2560x1440@144" }] }, []);

        verify(!merged.entries[0].hasOwnProperty("name"));
    }

    function test_parseWorldPosition_data() {
        return [
            { tag: "parses a plain XxY", text: "1920x0", expectNull: false, x: 1920, y: 0 },
            { tag: "parses negative coordinates", text: "-100x-50", expectNull: false, x: -100, y: -50 },
            { tag: "rejects text with no x separator", text: "not-a-position", expectNull: true },
            { tag: "rejects an empty string", text: "", expectNull: true }
        ];
    }

    function test_parseWorldPosition(row) {
        const result = ArrangeLogic.parseWorldPosition(row.text);
        if (row.expectNull) {
            compare(result, null);
        } else {
            compare(result.x, row.x);
            compare(result.y, row.y);
        }
    }

    function test_numberField_data() {
        return [
            { tag: "parses an integer", text: "1", expected: 1 },
            { tag: "parses a decimal", text: "1.5", expected: 1.5 },
            { tag: "keeps a real zero", text: "0", expected: 0 },
            { tag: "blank text is undefined, not zero", text: "", expected: undefined },
            { tag: "whitespace-only text is undefined", text: "   ", expected: undefined },
            { tag: "unparseable text is undefined", text: "abc", expected: undefined },
            // Number("Infinity") is a real, finite-looking JS number until
            // it hits JSON.stringify, which renders it as `null` — the
            // exact null isSet()/mergedOverrides exist to keep out of a
            // saved entry.
            { tag: "Infinity is undefined, not a value JSON would silently null out", text: "Infinity", expected: undefined },
            { tag: "-Infinity is undefined for the same reason", text: "-Infinity", expected: undefined }
        ];
    }

    function test_numberField(row) {
        compare(ArrangeLogic.numberField(row.text), row.expected);
    }

    function test_integerField_data() {
        return [
            { tag: "truncates a decimal down", text: "1.9", expected: 1 },
            { tag: "keeps zero", text: "0", expected: 0 },
            { tag: "blank text is undefined", text: "", expected: undefined }
        ];
    }

    function test_integerField(row) {
        compare(ArrangeLogic.integerField(row.text), row.expected);
    }

    function test_parseVrr_data() {
        return [
            { tag: "accepts off", text: "off", expected: "off" },
            { tag: "accepts left", text: "left", expected: "left" },
            { tag: "accepts right", text: "right", expected: "right" },
            { tag: "accepts auto", text: "auto", expected: "auto" },
            { tag: "rejects a typo instead of writing it raw", text: "on", expected: undefined },
            { tag: "rejects blank", text: "", expected: undefined },
            { tag: "trims surrounding whitespace before matching", text: "  left  ", expected: "left" },
            // A field this merge only ever adds to, never clears (see
            // mergedOverrides' own comment), makes a case mismatch worse
            // than an ordinary typo: a rejected "Off" over an existing
            // "left" silently leaves "left" in place rather than erroring.
            { tag: "accepts a capitalised value, matching the label's casing", text: "Off", expected: "off" },
            { tag: "accepts an all-caps value", text: "AUTO", expected: "auto" },
            { tag: "accepts mixed case", text: "Left", expected: "left" }
        ];
    }

    function test_parseVrr(row) {
        compare(ArrangeLogic.parseVrr(row.text), row.expected);
    }

    function test_parseTransform_data() {
        return [
            { tag: "accepts the low end of the range", text: "0", expected: 0 },
            { tag: "accepts the high end of the range", text: "7", expected: 7 },
            { tag: "rejects one above the range", text: "8", expected: undefined },
            { tag: "rejects a negative value", text: "-1", expected: undefined },
            { tag: "rejects blank", text: "", expected: undefined },
            { tag: "rejects unparseable text", text: "abc", expected: undefined }
        ];
    }

    function test_parseTransform(row) {
        compare(ArrangeLogic.parseTransform(row.text), row.expected);
    }

    // Regression guard for a dead read that was never caught by unit
    // tests on mergedOverrides itself: JsonAdapter has no `root` property
    // in this Quickshell version (confirmed against the shipped
    // quickshell-io.qmltypes, which declares qs::io::JsonAdapter with zero
    // Property entries), so Arrange.qml's own `.adapter.root` reads were
    // always undefined — every save silently discarded whatever
    // overrides.json already held, which is exactly the class of bug
    // every mergedOverrides test in this file could never see, since they
    // all call mergedOverrides directly with an explicit existingRoot and
    // never go through the live adapter at all. Reads Arrange.qml as text
    // (same idiom as tst_tint_wiring.qml, which qmltestrunner cannot
    // instantiate the component to check directly — this one CAN be
    // instantiated, but doing so would need a live Hyprland singleton and
    // PanelWindow, exactly what this file's own header says to avoid).
    function readArrangeSource() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../nix/home/desktop/quickshell/qml/monitors/Arrange.qml"), false);
        xhr.send();
        compare(xhr.status, 200, "Arrange.qml must be readable (needs QML_XHR_ALLOW_FILE_READ=1)");
        return xhr.responseText;
    }

    // Scoped to the JsonAdapter block itself, not a bare indexOf over the
    // whole file: this file already declares several other `property var`
    // fields (monitorsSnapshot, transform, pendingEdits), so an unscoped
    // check for the substring "property var" would pass against source
    // that never declared anything on the adapter at all.
    function jsonAdapterBlock() {
        const source = readArrangeSource();
        const marker = "adapter: JsonAdapter {";
        const start = source.indexOf(marker);
        verify(start !== -1, "overridesFile must declare adapter: JsonAdapter { ... }");
        // Brace-counted from the JsonAdapter's own opening brace to its
        // matching close, rather than a fixed-indentation "\n        }"
        // search — that would silently widen the slice (and so the scope
        // of the check below) if the declaration were ever reformatted
        // onto one line: the intended close would no longer sit at that
        // exact indentation, and the search would instead land on some
        // later, unrelated closing brace, weakening the scoping rather
        // than failing outright.
        let depth = 0;
        let i = start + marker.length - 1;
        for (; i < source.length; i++) {
            if (source[i] === "{")
                depth++;
            else if (source[i] === "}") {
                depth--;
                if (depth === 0)
                    break;
            }
        }
        verify(depth === 0, "the JsonAdapter block's closing brace must be found");
        return source.slice(start, i + 1);
    }

    function test_Arrange_qml_declares_the_adapter_shape_it_actually_reads() {
        const block = jsonAdapterBlock();
        verify(block.indexOf("property var entries") !== -1, "JsonAdapter must declare an entries property — it has no root property to fall back on");
    }

    function test_Arrange_qml_never_reads_the_nonexistent_adapter_root() {
        const source = readArrangeSource();
        verify(source.indexOf(".adapter.root") === -1, "Arrange.qml must never read .adapter.root — JsonAdapter has no such property in this Quickshell version, so every such read is silently undefined");
    }

    // Scoped to overridesRoot's own block via the same brace-counting idiom
    // as jsonAdapterBlock() above, rather than a bare indexOf over the whole
    // file: the property's own explanatory comment names both `instanceof
    // Array` and `Array.isArray`, so an unscoped scan of either identifier
    // would be satisfied (or defeated) by prose rather than the binding.
    function overridesRootBlock() {
        const source = readArrangeSource();
        const marker = "readonly property var overridesRoot: {";
        const start = source.indexOf(marker);
        verify(start !== -1, "Arrange.qml must declare overridesRoot");
        let depth = 0;
        let i = start + marker.length - 1;
        for (; i < source.length; i++) {
            if (source[i] === "{")
                depth++;
            else if (source[i] === "}") {
                depth--;
                if (depth === 0)
                    break;
            }
        }
        verify(depth === 0, "overridesRoot's closing brace must be found");
        return source.slice(start, i + 1);
    }

    // Quickshell wraps a JsonAdapter's loaded QVariantList as a V4Sequence,
    // not a genuine JS Array exotic object: Array.isArray returns false for
    // it while `instanceof Array` returns true, confirmed live against the
    // real quickshell binary (see overridesRoot's own comment). A
    // regression back to Array.isArray would silently discard every
    // successfully loaded overrides.json and keep the empty default.
    // qmltestrunner cannot load Quickshell.Io to instantiate a real
    // JsonAdapter and exercise that distinction directly (tests/README.md),
    // so this pins the source text instead, the same idiom
    // tst_tint_wiring.qml uses for a caller qmltestrunner cannot construct.
    function test_overridesRoot_guards_with_instanceof_array_not_isArray() {
        const block = overridesRootBlock();
        verify(block.indexOf("instanceof Array") !== -1, "overridesRoot must guard the adapter's entries with `instanceof Array`");
        verify(block.indexOf("Array.isArray") === -1, "overridesRoot must not regress to Array.isArray, which returns false for Quickshell's V4Sequence and would discard every loaded override");
    }
}
