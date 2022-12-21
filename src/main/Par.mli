val run : (unit -> 'a) -> 'a
(** Run parallel / concurrent code. *)

val par : (unit -> 'a) -> (unit -> 'b) -> 'a * 'b
(** Run the two given actions potentially in parallel.  Parallel execution is
    not guaranteed. *)

module Fiber : sig
  type 'a t

  val spawn : (unit -> 'a) -> 'a t
  val join : 'a t -> 'a
end

module Continuation : sig
  type 'a t

  val suspend : ('a t -> unit) -> 'a
  val return : 'a t -> 'a -> unit
  val raise : 'a t -> exn -> unit
end
