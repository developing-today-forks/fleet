{
  description = "developing-today fleet umbrella — canonical shared pins";

  # This flake exists to be the fleet's single nixpkgs pin source.
  # Consumer repos (opencode, openchamber, code) declare:
  #
  #   inputs.fleet.url = "github:dezren39/fleet";
  #   inputs.nixpkgs.follows = "fleet/nixpkgs";
  #
  # so every repo builds against the SAME nixpkgs revision and their
  # dev shells share one store closure instead of three overlapping
  # ones. The pin is always a nixpkgs-unstable CHANNEL TIP revision —
  # by definition the newest revision Hydra has fully evaluated and
  # built for the channel, which maximises cache.nixos.org hit rate.
  # Never pin an arbitrary master snapshot here.
  #
  # To move the fleet: update the rev below to the current
  # nixpkgs-unstable tip, run `nix flake lock`, merge; then each
  # consumer runs `nix flake lock` to pick it up.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/f9887a8a434bfba06e20dfc77bc8e0628266af84";
  };

  outputs =
    { self, nixpkgs, ... }:
    {
      # Exposed so tooling can read the pin without parsing the lock.
      fleetNixpkgsRev = nixpkgs.rev;
    };
}
