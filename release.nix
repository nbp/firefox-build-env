{ gecko ? { outPath = ./mozilla-central /* Specify this on the command line if using nix-build. */; revCount = 1234; shortRev = "abcdef"; }
, officialRelease ? false
}:

let

  pkgs = import <nixpkgs> {};

  # Make an attribute set for each system, the builder is then specialized to
  # use the selected system.
  forEachSystem = builder: pkgs: pkgs.lib.genAttrs [ "x86_64-linux" "i686-linux" /* "x86_64-darwin" */ ] (system:
    let pkgs = import <nixpkgs> { inherit system; }; in
      builder pkgs
  );

  # Make an attribute set for each compiler, the builder is then be specialized
  # to use the selected compiler.
  forEachCompiler = builder: pkgs: with pkgs; let

    # Override, in a non-recursive matter to avoid recompilations, the standard
    # environment used for building packages.
    builderWithStdenv = stdenv: builder (pkgs // { inherit stdenv; });

    noSysDirs = (system != "x86_64-darwin"
               && system != "x86_64-freebsd" && system != "i686-freebsd"
               && system != "x86_64-kfreebsd-gnu");
    crossSystem = null;

    gcc473 = wrapGCC (callPackage ./gcc-4.7 {
      inherit noSysDirs;
      texinfo = texinfo4;
      # I'm not sure if profiling with enableParallelBuilding helps a lot.
      # We can enable it back some day. This makes the *gcc* builds faster now.
      profiledCompiler = false;
  
      # When building `gcc.crossDrv' (a "Canadian cross", with host == target
      # and host != build), `cross' must be null but the cross-libc must still
      # be passed.
      cross = null;
      libcCross = if crossSystem != null then libcCross else null;
      libpthreadCross =
        if crossSystem != null && crossSystem.config == "i586-pc-gnu"
        then gnu.libpthreadCross
        else null;
    });

    buildWithCompiler = cc:
      builderWithStdenv (
        if stdenvAdapters ? overrideGCC then # Nixpkgs 14.12
          stdenvAdapters.overrideGCC stdenv cc
        else # Latest nixpkgs
          stdenvAdapters.overrideCC stdenv cc
      );
    chgCompilerSource = cc: name: src:
      cc.override (conf:
        if conf ? gcc then # Nixpkgs 14.12
          { gcc = lib.overrideDerivation conf.gcc (old: { inherit name src; }); }
        else # Latest nixpkgs
          { cc = lib.overrideDerivation conf.cc (old: { inherit name src; }); }
      );

  in {
    clang = builderWithStdenv clangStdenv;
    clang33 = buildWithCompiler clang_33;
    clang34 = buildWithCompiler clang_34;
    clang35 = buildWithCompiler clang_35;
    gcc = builderWithStdenv stdenv;
    gcc49 = buildWithCompiler gcc49;
    gcc48 = buildWithCompiler gcc48;
    gcc474 = buildWithCompiler (chgCompilerSource gcc473 "gcc-4.7.4" (fetchurl {
      url = "mirror://gnu/gcc/gcc-4.7.4/gcc-4.7.4.tar.bz2";
      sha256 = "10k2k71kxgay283ylbbhhs51cl55zn2q38vj5pk4k950qdnirrlj";
    }));
    gcc473 = buildWithCompiler gcc473;
    # Version used on Linux slaves, except Linux x64 ASAN.
    gcc472 = buildWithCompiler (chgCompilerSource gcc473 "gcc-4.7.2" (fetchurl {
      url = "mirror://gnu/gcc/gcc-4.7.2/gcc-4.7.2.tar.bz2";
      sha256 = "115h03hil99ljig8lkrq4qk426awmzh0g99wrrggxf8g07bq74la";
    }));
  };

  

  jobs = rec {

    # For each system, and each compiler, create an attribute with the name of
    # the system and compiler. Use this attribute name to select which
    # environment you are interested in for building firefox.  These can be
    # build using the following command:
    #
    #   $ nix-build ./build/nix/release.nix -A build.x86_64-linux.clang -o firefox-x64
    #   $ nix-build ./build/nix/release.nix -A build.i686-linux.gcc48 -o firefox-x86
    #
    # If you are only interested in getting a build environment, the use the
    # nix-shell command instead, which will skip the copy of Firefox sources,
    # and pull the the dependencies needed for building firefox with this
    # environment.
    #
    #   $ nix-shell ./build/nix/release.nix -A build.i686-linux.gcc472 --pure --command 'gcc --version'
    #   $ nix-shell ./build/nix/release.nix -A build.x86_64-linux.clang --pure
    #
    build = forEachSystem (forEachCompiler (pkgs: with pkgs;

      stdenv.mkDerivation {
        name = "firefox";
        src = if lib.inNixShell then null else gecko;

        buildInputs = [
          # Expected by "mach"
          python which autoconf213

          # Expected by the configure script
          perl unzip zip gnumake yasm pkgconfig

          xlibs.libICE xlibs.libSM xlibs.libX11 xlibs.libXau xlibs.libxcb
          xlibs.libXdmcp xlibs.libXext xlibs.libXt xlibs.printproto
          xlibs.renderproto xlibs.xextproto xlibs.xproto xlibs.libXcomposite
          xlibs.compositeproto xlibs.libXfixes xlibs.fixesproto
          xlibs.damageproto xlibs.libXdamage xlibs.libXrender xlibs.kbproto

          gnome.libart_lgpl gnome.libbonobo gnome.libbonoboui
          gnome.libgnome gnome.libgnomecanvas gnome.libgnomeui
          gnome.libIDL

          gtkLibs.pango gtk3

          dbus dbus_glib

          alsaLib
          (if pkgs ? pulseaudio then # Nixpkgs 14.12
             pulseaudio
           else # Latest nixpkgs
             libpulseaudio
          )
          gstreamer gst_plugins_base
        ] ++ lib.optionals lib.inNixShell [
          valgrind
        ];

        # Useful for debugging this Nix expression.
        tracePhases = true;

        configurePhase = ''
          export MOZBUILD_STATE_PATH=$(pwd)/.mozbuild
          export MOZCONFIG=$(pwd)/.mozconfig
          export builddir=$(pwd)/build

          mkdir -p $MOZBUILD_STATE_PATH $builddir
          echo > $MOZCONFIG "
          . $src/build/mozconfig.common

          ac_add_options --prefix=$out
          ac_add_options --enable-application=browser
          ac_add_options --enable-official-branding
          "

          # Make sure mach can find autoconf 2.13, as it is not suffixed in Nix.
          export AUTOCONF=${autoconf213}/bin/autoconf
        '';

        AUTOCONF = "${autoconf213}/bin/autoconf";

        buildPhase = ''
          cd $builddir
          $src/mach build
        '';

        installPhase = ''
          cd $builddir
          $src/mach install
        '';

        doCheck = false;
        doInstallCheck = false;
      })) pkgs;

  };

in
  jobs
