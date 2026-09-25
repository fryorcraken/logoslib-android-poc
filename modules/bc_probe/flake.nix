{
  description = "bc-desktop: a minimal universal module whose only job is to call blockchain_module over LogosAPI";

  inputs = {
    # Same module-builder rev blockchain_module 4b07e58 locks (tag 0.3.1), so the SDK/Qt closure is shared.
    logos-module-builder.url = "github:logos-co/logos-module-builder/16e2f6bd3c06a5119f8c34448933de183205646c";
    # Input name == dependency name in metadata.json; the builder resolves modules().blockchain_module from it.
    blockchain_module.url = "github:logos-blockchain/logos-blockchain-module/4b07e58b8ae9bfea3e953f234c97d1f276e799a0";
  };

  outputs = inputs@{ logos-module-builder, ... }:
    logos-module-builder.lib.mkLogosModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
    };
}
