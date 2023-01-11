include Stdlib.Atomic

let fence atomic = fetch_and_add atomic 0 |> ignore [@@inline]
