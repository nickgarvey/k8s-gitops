
{
	description = "K8s GitOps development environment";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
		flake-utils.url = "github:numtide/flake-utils";
	};

	outputs = { self, nixpkgs, flake-utils }:
		flake-utils.lib.eachDefaultSystem (system:
			let
				pkgs = import nixpkgs { inherit system; };
			in {
				devShells = {
					default = pkgs.mkShell {
					buildInputs = [
						pkgs.kubectl
						pkgs.skopeo
					];
            shellHook = ''
            export PS1="[k8s-gitops] \[\033[1;32m\][\[\e]0;\u@\h: \w\a\]\u@\h:\w]\$\[\033[0m\] "
            '';
					};
				};
			}
		);
}
