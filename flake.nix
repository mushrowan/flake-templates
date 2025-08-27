{
  description = "Rowan's Nix templates";

  outputs = { self }: {

    templates = {

      rust-crane = {
        path = ./rust-crane;
        description = "Rust template, using Crane";
      };

    };

    defaultTemplate = self.templates.trivial;

  };
}
