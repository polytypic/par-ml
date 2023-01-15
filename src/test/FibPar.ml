open Par

let num_domains = try int_of_string_opt Sys.argv.(1) with _ -> None
let n = try int_of_string Sys.argv.(2) with _ -> 30

let rec fib n =
  if n <= 1 then n
  else
    let n1, n2 = par (fun () -> fib (n - 1)) (fun () -> fib (n - 2)) in
    n1 + n2

let () =
  Idle_domains.prepare_opt ~num_domains;

  run @@ fun () -> Printf.printf "fib %d = %d\n" n (fib n)
