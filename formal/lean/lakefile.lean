import Lake
open Lake DSL

package mutation where

@[default_target]
lean_lib Mutation where

lean_exe replay where
  root := `Mutation.Replay
