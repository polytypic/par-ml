open Par

let num_domains = try int_of_string_opt Sys.argv.(1) with _ -> None
let n = try int_of_string Sys.argv.(2) with _ -> 30

let rec fib n =
  if n <= 1 then n
  else
    let n2 = Fiber.spawn @@ fun () -> fib (n - 2) in
    let n1 = fib (n - 1) in
    n1 + Fiber.join n2

let () =
  Idle_domains.prepare_opt ~num_domains;

  Printf.printf "fib %d = %d\n" n (run @@ fun () -> fib n)
