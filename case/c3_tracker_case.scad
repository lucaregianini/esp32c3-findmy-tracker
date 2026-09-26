// C3 Find My tracker, AirTag-inspired case (lightweight version)
//
// Stack, from the back up:
//   back plate (white) -> 3x AA holder, cells facing the back -> 12 mm space for
//   the ESP32-C3 SuperMini and the battery-level divider -> top (white).
// Undo the 2 screws on the back to reach the batteries.
//
// Parts (print flat, no supports):
//   shell : white, TOP FACE DOWN, red for the last accent_h mm (pinstripe at the base)
//   back  : white, outside face down
//
// Weight: thin even walls that follow the rounded top, hollow ends with slim
// screw pillars, and a thin rib at the tape end instead of solid end walls.
//
// Open in OpenSCAD > Window > Customizer to change any value.

/* [Show / export] */
part = "both"; // [both, shell, back, assembled]

/* [Battery holder] */
holder_l = 58;      // along the cells
holder_w = 47;      // across the 3 cells
holder_h = 21;      // with the cells in (they overhang the holder), measured 20-21
side_clr = 0.5;     // along the long sides: 48 mm inside (snug; thin tape only)
tape_gap = 1.0;     // short end without wires: ~1 mm double-sided foam tape on the rib
wire_gap = 4.0;     // short end where the wires come out and go up
top_space = 8;      // above the holder's flat side: C3 (~5 mm with USB-C) + divider + wires

/* [Shell] */
squircle_n = 6;     // 4-6 = Apple-like rounded square
top_round = 7;      // softness of the top edge
wall = 1.2;        // 3 lines of a 0.4 nozzle; the curved shape carries the stiffness
top_t = 1.2;
back_t = 1.4;       // flat panel under the batteries: kept a bit thicker
boss_t = 0.5;       // ring around each screw on the back plate (countersink sits in 1.9 mm)
rib_t = 1.6;        // flat rib the holder is taped to

/* [Screws: ordinary 3-4 mm wood screws, 12-20 mm long, countersunk] */
screw_pilot_d = 2.8;
screw_clear_d = 4.2;
screw_head_d = 7.6;
pillar_d = 8.0;     // leaves ~0.9 mm around the back plate's boss recess

/* [Colour accent] */
// A red pinstripe around the base of the shell, just above the white back.
// The shell prints face down, so this is simply its last layers: one
// filament change in Bambu Studio at z = H - accent_h (set in the 3MF).
accent_h = 1.4;

/* [Lanyard eyelet] */
eyelet_d = 4.5;
eyelet_tube_d = 8.0;

$fn = 72;

// ---------------------------------------------------------------- derived
in_l = tape_gap + holder_l + wire_gap;   // holder bay, x from -in_l/2 (tape end) to +in_l/2 (wire end)
in_w = holder_w + 2 * side_clr;
in_h = holder_h + 0.5 + top_space;
L = in_l + 2 * (rib_t + pillar_d + wall) - 1.0;
W = in_w + 2 * wall + 2.4;              // keeps the squircle corners >= 2 mm from the holder
H = top_t + in_h;                       // shell, top face at z = 0 (print orientation)

tape_pillar_x = -(in_l / 2 + rib_t + pillar_d / 2) + 0.3;   // overlaps the rib (not just touching it)
wire_pillar_x = L / 2 - wall - pillar_d / 2 + 0.6;   // fused into the end wall
screws = [[tape_pillar_x, 0], [wire_pillar_x, 0]];
eyelet_pos = [-(in_l / 2 + rib_t + eyelet_tube_d / 2 - 0.8), in_w / 2 - 8.5];   // ~2 mm of plastic outside the hole

// ---------------------------------------------------------------- shapes
function sgn(v) = v < 0 ? -1 : 1;
module squircle(l, w, n = squircle_n) {
    polygon([for (t = [0 : 359])
        [l / 2 * sgn(cos(t)) * pow(abs(cos(t)), 2 / n),
         w / 2 * sgn(sin(t)) * pow(abs(sin(t)), 2 / n)]]);
}

// Printable rounded edge: flat face, 45 degree start, then a true radius.
function edge_inset(z, r) =
    z >= r ? 0 : min(r - sqrt(r * r - (r - z) * (r - z)), 0.586 * r - z);

// Rounded-top body, shrunk inward by `shrink` everywhere (used for the
// outside with shrink = 0 and for the hollow inside with shrink = wall).
module body(h, shrink = 0, z0 = 0) {
    steps = 16;
    r = top_round;
    hull() {
        for (i = [0 : steps]) let(z = r * i / steps) if (z >= z0)
            translate([0, 0, z]) linear_extrude(0.01)
                offset(delta = -(shrink + max(edge_inset(z, r), 0))) squircle(L, W);
        translate([0, 0, z0]) linear_extrude(0.01)
            offset(delta = -(shrink + max(edge_inset(z0, r), 0))) squircle(L, W);
        translate([0, 0, h - 0.02]) linear_extrude(0.02) offset(delta = -shrink) squircle(L, W);
    }
}

boss_d = 5.8;       // ring around the countersink on the back; seats into the pillar
module rib_window() {
    x0 = -in_l / 2 - rib_t - 0.5;
    z_lo = top_t + 3;                        // keeps a solid band under the top
    z_hi = H - (holder_h + 0.5) - 3;          // keeps the rib full over the holder
    w = in_w - 12;
    if (z_hi - z_lo > w / 2 + 2)
        translate([x0, 0, 0]) rotate([90, 0, 90]) linear_extrude(rib_t + 1)
            polygon([[-w / 2, z_lo + w / 2], [0, z_lo], [w / 2, z_lo + w / 2],
                     [w / 2, z_hi - w / 2], [0, z_hi], [-w / 2, z_hi - w / 2]]);
    else if (z_hi - z_lo > 4)
        translate([x0, 0, 0]) rotate([90, 0, 90]) linear_extrude(rib_t + 1) let(h = (z_hi - z_lo) / 2)
            polygon([[-h, z_lo + h], [0, z_lo], [h, z_lo + h], [0, z_hi]]);
}

// ---------------------------------------------------------------- parts
module shell() {
    difference() {
        union() {
            difference() {
                body(H);
                // hollow inside: follows the outside at an even wall thickness
                translate([0, 0, 0]) body(H + 1, wall, top_t);
            }
            intersection() {
                body(H);
                union() {
                    // slim screw pillars, full height
                    for (s = screws) translate([s[0], s[1], 0]) cylinder(d = pillar_d, h = H);
                    // flat rib at the tape end: the holder is taped to it
                    translate([-in_l / 2 - rib_t, -in_w / 2, 0]) cube([rib_t, in_w, H]);
                    // lanyard tube
                    translate([eyelet_pos[0], eyelet_pos[1], 0]) cylinder(d = eyelet_tube_d, h = H);
                }
            }
        }
        for (s = screws) translate([s[0], s[1], top_t + 1]) cylinder(d = screw_pilot_d, h = H);
        // recess where the back plate's screw bosses seat (also locates the back)
        for (s = screws) translate([s[0], s[1], H - boss_t - 0.2]) cylinder(d = boss_d + 0.4, h = boss_t + 1.2);   // open at the rim
        // window in the tape rib above the battery zone, pointed top so it prints without supports
        rib_window();
        translate([eyelet_pos[0], eyelet_pos[1], -1]) cylinder(d = eyelet_d, h = H + 2);
    }
}

// modelled with the outside face on the bed; flipped over onto the shell,
// so Y is mirrored relative to the shell
module back() {
    difference() {
        union() {
            hull() {
                linear_extrude(0.01) offset(delta = -0.8) squircle(L, W);
                translate([0, 0, 0.8]) linear_extrude(back_t - 0.8) squircle(L, W);
            }
            for (s = screws) translate([s[0], -s[1], 0]) cylinder(d = boss_d, h = back_t + boss_t);
        }
        for (s = screws) translate([s[0], -s[1], -0.01]) {
            cylinder(d = screw_clear_d, h = back_t + boss_t + 1);
            cylinder(d1 = screw_head_d, d2 = screw_clear_d, h = (screw_head_d - screw_clear_d) / 2);
        }
        translate([eyelet_pos[0], -eyelet_pos[1], -1]) cylinder(d = eyelet_d, h = back_t + 2);
    }
}

// ---------------------------------------------------------------- output
if (part == "shell") shell();
else if (part == "back") back();
else if (part == "assembled") {
    translate([0, 0, H + back_t]) mirror([0, 0, 1]) {
        color("white") intersection() { shell(); translate([-L, -W, -1]) cube([2 * L, 2 * W, H - accent_h + 1]); }
        color([0.8, 0.1, 0.12]) intersection() { shell(); translate([-L, -W, H - accent_h]) cube([2 * L, 2 * W, accent_h + 1]); }
    }
    color("white") mirror([0, 1, 0]) back();
}
else {
    shell();
    translate([0, W + 10, 0]) back();
}

echo(str("Outer size: ", L, " x ", W, " x ", H + back_t, " mm"));
echo(str("Shell height H = ", H, " mm; red accent from z = ", H - accent_h));
