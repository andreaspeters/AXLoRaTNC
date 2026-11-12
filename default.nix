with import <nixpkgs> {};

stdenv.mkDerivation {
name = "platform-env";


buildInputs = [
  platformio
  gnumake
	nodejs
];

S_CONTAINER="false";

SOURCE_DATE_EPOCH = 315532800;
PROJDIR = "${toString ./.}";

shellHook = ''
  export TMPDIR=/tmp
  '';
}


