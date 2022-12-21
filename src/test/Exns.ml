open Par

exception Expected of int

let test_par () =
  match par (fun () -> 101) (fun () -> raise @@ Expected 42) with
  | _ -> failwith "unexpected"
  | exception Expected 42 -> ()

let test_spawn () =
  match
    let _ = Fiber.spawn @@ fun () -> raise @@ Expected 101 in
    let fib2 = Fiber.spawn @@ fun () -> raise @@ Expected 21 in
    Fiber.join fib2
  with
  | _ -> failwith "unexpected"
  | exception Expected 21 -> ()

let () =
  run @@ fun () ->
  let _ = test_par () in
  let _ = test_spawn () in
  ()
