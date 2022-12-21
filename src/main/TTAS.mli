type t

val make : unit -> t
val acquire : t -> unit
val release : t -> unit
val protect : t -> (unit -> unit) -> unit
