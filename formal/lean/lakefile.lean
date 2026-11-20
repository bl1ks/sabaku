import Lake
open Lake DSL

package sabaku where

@[default_target]
lean_lib Sabaku where

lean_exe replay where
  root := `Sabaku.Replay
