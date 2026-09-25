{
  description = "desktop-harness: a minimal universal module that emits events and can block on demand";

  inputs = {
    # Same module-builder rev as lez_probe / lez_core 825d2a4, so the SDK/Qt closure is shared.
    logos-module-builder.url = "github:logos-co/logos-module-builder/6ef42ea8661121831ece79e6b702e27ac1cf46e7";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
