include Stdlib.Atomic

let get_compare_and_set atomic expect value =
  if get atomic == expect then compare_and_set atomic expect value |> ignore
  [@@inline]
