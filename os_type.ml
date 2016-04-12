let () =
  prerr_endline "Checking the compiler is Cygwin OCaml...";
  assert (Sys.os_type = "Cygwin")
