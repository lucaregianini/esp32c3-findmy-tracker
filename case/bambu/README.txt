Flattened Bambu Studio profiles used to build the 3MF files in ../print:
  machine.json                      Bambu Lab A2L 0.4 nozzle
  process_020_standard_A2L.json     0.20mm Standard @BBL A2L
  pla_white.json / pla_red.json     Bambu PLA Basic @BBL A2L 0.4 nozzle (+ colour)

Rebuild after changing the model (run from the project folder):
  B=/Applications/BambuStudio.app/Contents/MacOS/BambuStudio; D=$PWD/bambu
  "$B" --slice 0 --arrange 1 --orient 0 --outputdir "$PWD/print" \
     --load-settings "$D/machine.json;$D/process_020_standard_A2L.json" \
     --load-filaments "$D/pla_white.json" --export-3mf "C3 Tracker - Shell (white PLA).3mf" "$PWD/c3_tracker_shell.stl"
  (same with pla_red.json and c3_tracker_back.stl for the back)

Red accent stripe (shell only): the shell 3MF also loads pla_red.json as filament 2 and
contains custom_gcode_per_layer.xml (copy kept here): one tool change to filament 2 at
top_z = H - accent_h (rounded to a 0.2 mm layer; 33.6 for H = 34.7). Prime tower is off
(enable_prime_tower = 0) because the A2L purges into its chute. If H changes, update top_z.
To rebuild: slice the shell with "--load-filaments white;red --load-filament-ids 1",
unzip, add this XML to Metadata/, set enable_prime_tower to "0" in
Metadata/project_settings.config, delete Metadata/plate_1.gcode*, re-zip, and re-slice
that 3MF with the CLI.
