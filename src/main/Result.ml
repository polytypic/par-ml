include Stdlib.Result

let run = function Ok x -> x | Error e -> raise e
