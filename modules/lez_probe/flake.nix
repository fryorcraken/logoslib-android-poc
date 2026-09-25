{
  description = "desktop-probe: a minimal universal module whose only job is to call lez_core over LogosAPI";

  inputs = {
    # Same module-builder rev the LEZ module's lock uses, so the SDK/Qt closure is shared.
    logos-module-builder.url = "github:logos-co/logos-module-builder/6ef42ea8661121831ece79e6b702e27ac1cf46e7";
    # Input name == dependency name in metadata.json; the builder resolves modules().lez_core from it.
    lez_core.url = "github:logos-blockchain/logos-execution-zone-module/825d2a41262b9882aa0f9ca837cb03635f7980c2";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
