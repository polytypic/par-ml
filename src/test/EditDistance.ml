(* Based on https://github.com/kayceesrk/experiment-with-ocaml-5/blob/memoized/bench/bench.ml *)

open Par

module Memo = struct
  let memo ~get ~set f x y =
    let res = get x y in
    if res = -1 then begin
      let res = f x y in
      set x y res;
      res
    end
    else res

  let memo_rec ~get ~set f_norec =
    let f_ref = ref (fun _ -> assert false) in
    let f_rec_memo = memo ~get ~set (fun x y -> f_norec !f_ref x y) in
    f_ref := f_rec_memo;
    f_rec_memo
end

module SuffixString = struct
  type t = {str : String.t; len : int}

  let mk s = {str = s; len = String.length s}
  let length {len; _} = len
  let drop_suffix {str; len} n = {str; len = len - n}
  let get {str; _} n = str.[n]
end

module Sequential = struct
  let edit_distance f s t =
    match (SuffixString.length s, SuffixString.length t) with
    | 0, x | x, 0 -> x
    | len_s, len_t ->
      let s' = SuffixString.drop_suffix s 1 in
      let t' = SuffixString.drop_suffix t 1 in
      let cost_to_drop_both =
        if SuffixString.get s (len_s - 1) = SuffixString.get t (len_t - 1) then
          0
        else 1
      in
      let d1 = f s' t + 1 in
      let d2 = f s t' + 1 in
      let d3 = f s' t' + cost_to_drop_both in
      let ( ++ ) = Int.min in
      d1 ++ d2 ++ d3
end

module Parallel = struct
  let edit_distance seq_ed s t =
    (* Fill the memo table by computing the edit distance for the 4 quadrants
       (recursively, for a small recursion depth) in parallel. *)
    let rec helper depth s t =
      if depth > 4 then seq_ed s t
      else
        let open SuffixString in
        let s' = drop_suffix s (length s / 2) in
        let t' = drop_suffix t (length t / 2) in
        par
          (fun () ->
            par
              (fun () -> helper (depth + 1) s' t')
              (fun () -> helper (depth + 1) s t')
            |> snd)
          (fun () ->
            par
              (fun () -> helper (depth + 1) s' t)
              (fun () -> helper (depth + 1) s t)
            |> snd)
        |> snd
    in
    helper 0 s t
end

let () =
  let num_domains = try int_of_string_opt Sys.argv.(1) with _ -> None in
  Idle_domains.prepare_opt ~num_domains;

  run @@ fun () ->
  let use_seq = try Sys.argv.(2) = "seq" with _ -> false in
  let a =
    try Sys.argv.(3)
    with _ -> String.init 5000 (fun _ -> Char.chr (Random.int 127 + 1))
  in
  let b =
    try Sys.argv.(4)
    with _ -> String.init 5000 (fun _ -> Char.chr (Random.int 127 + 1))
  in
  let open SuffixString in
  let a = mk a in
  let b = mk b in
  let table = Array.make_matrix (length a + 1) (length b + 1) (-1) in
  (* We don't use atomic instructions to read and write to the memo table. The
     memory model ensures that there are no out-of-thin-air values. Hence, the
     value in a cell will either be the initial value [-1] or the computed
     result. Multiple tasks may compute the result for the same cell. But all of
     them compute the same result. *)
  let get a b = table.(length a).(length b) in
  let set a b res = table.(length a).(length b) <- res in
  let seq_ed = Memo.memo_rec ~get ~set Sequential.edit_distance in
  if use_seq then Printf.printf "%d\n" (seq_ed a b : int)
  else Printf.printf "%d\n" (Parallel.edit_distance seq_ed a b : int)
