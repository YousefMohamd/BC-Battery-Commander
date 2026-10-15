#!/usr/bin/env bats

profile_for() {
  EXT="$1"; CLAM="$2"
  if [ "$EXT" = "No" ] && [ "$CLAM" = "Yes" ]; then echo "long_battery"
  elif [ "$EXT" = "No" ] && [ "$CLAM" = "No" ]; then echo "active_battery"
  elif [ "$EXT" = "Yes" ] && [ "$CLAM" = "Yes" ]; then echo "long_ac"
  else echo "active_ac"; fi
}

@test "battery+lid closed -> long_battery" { run profile_for No Yes; [ "$output" = "long_battery" ]; }
@test "battery+lid open -> active_battery" { run profile_for No No; [ "$output" = "active_battery" ]; }
@test "ac+lid open -> active_ac" { run profile_for Yes No; [ "$output" = "active_ac" ]; }
