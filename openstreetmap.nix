{ config, pkgs, lib, ... }:

let

  cfg = config.services.openstreetmap;

  renderdHome = "/var/lib/renderd";
  renderdShare = "/var/lib/renderd_share";
  renderdSocket = "${renderdShare}/renderd.sock";
  tileDir = "${renderdShare}/tiles";

  osm-carto = pkgs.fetchFromGitHub {
    owner = "gravitystorm";
    repo = "openstreetmap-carto";
    rev = "445e5532b934dc68c7a4b0d3929e188bb837ae5a";
    sha256 = "sha256-h8a5HPrOp2G9NOSb4CWiLX3PvL1P9VDqZvjqKIvoqns=";
  };

  mapnik-carto =
    let
      env = { nativeBuildInputs = [ pkgs.nodePackages_latest.carto ]; };
    in
    pkgs.runCommand "mapnik-carto" env ''
      mkdir $out
      cd $out
      cp -r ${osm-carto}/* .
      carto --file mapnik.xml project.mml
    '';
  osm2pgsql-runner = pkgs.writeShellApplication {
    name = "osm-osm2pgsql-runner";
    runtimeInputs = with pkgs; [ osm2pgsql postgresql ];
    text = ''
      cores=$(nproc)
      mem=$(($(free -m | awk '/^Mem:/{print $2}') * 3 / 4))
      echo "Running with $cores cores and $mem MB of RAM"

      # shellcheck disable=SC2068
      osm2pgsql \
        --database=gis \
        --create \
        --slim \
        --drop \
        --multi-geometry \
        --hstore \
        "--tag-transform-script=${osm-carto}/openstreetmap-carto.lua" \
        "--cache=$mem" \
        "--number-processes=$cores" \
        --flat-nodes=nodes.cache \
        "--style=${osm-carto}/openstreetmap-carto.style" \
        $@

      psql -d gis -f ${osm-carto}/indexes.sql
    '';
  };

  osm-carto-get-external-data = pkgs.writeShellApplication {
    name = "osm-get-external-data";
    runtimeInputs = with pkgs; [
      (python3.withPackages (p: with p; [ pyaml requests psycopg2 ]))
      gdal
    ];
    text = ''
      ${osm-carto}/scripts/get-external-data.py \
        --config ${osm-carto}/external-data.yml
    '';
  };
  osm-carto-get-fonts = pkgs.writeShellApplication {
    name = "osm-get-fonts";
    runtimeInputs = with pkgs; [ curl unzip ];
    text = ''
      cd ${renderdShare}
      ${osm-carto}/scripts/get-fonts.sh
    '';
  };

  # https://lists.openstreetmap.org/pipermail/dev/2017-January/029662.html
  # "Higher zooms (12+) typically take about 1 second per 8x8 metatile per
  # CPU thread. 15+ tiles are not pre-rendered for the world, they are
  # rendered on demand and cached. The OSMF pre-renders z0-z12 tiles, and it
  # takes about a day to do this."
  osm-prerender-everything = pkgs.writeShellApplication {
    name = "osm-prerender-everything";
    runtimeInputs = [ mod_tile ];
    text = ''
      # shellcheck disable=SC2068
      render_list \
        --socket=${renderdSocket} \
        --tile-dir=${tileDir} \
        --map=s2o \
        --all \
        --force \
        --num-threads=${builtins.toString cfg.threads} \
        $@
    '';
  };

  renderdConfigFile = pkgs.writeText "renderd.conf" ''
    [mapnik]
    font_dir_recurse=true
    font_dir=${renderdShare}/fonts
    plugins_dir=${pkgs.mapnik}/lib/mapnik/input

    [renderd]
    pid_file=${renderdShare}/renderd.pid
    stats_file=${renderdShare}/renderd1.stats
    socketname=${renderdSocket}
    num_threads=${builtins.toString cfg.threads}
    tile_dir=${tileDir}

    [s2o]
    HOST=localhost
    MAXZOOM=${builtins.toString cfg.maxZoom}
    TILEDIR=${tileDir}
    TILESIZE=256
    URI=/hot/
    XML=${mapnik-carto}/mapnik.xml
  '';

  inherit (pkgs.apacheHttpdPackages) mod_tile;

in
{
  options = {
    services.openstreetmap = {
      enable = lib.mkEnableOption "openstreetmap hosting";
      debug = lib.mkEnableOption "debug outputs in journal";
      threads = lib.mkOption {
        type = lib.types.int;
        default = 1;
        description = "Number of threads to use for parallelizable tasks";
      };
      maxZoom = lib.mkOption {
        type = lib.types.int;
        default = 20;
        description = "Maximum zoom level";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 80;
        description = "Port to serve the tiles over HTTP on";
      };
      totalRamGb = lib.mkOption {
        type = lib.types.int;
        description = "Amount of RAM available on the machine. Will be used for DB tuning settings";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    users.extraGroups.renderd = { };
    users.extraUsers.renderd = {
      isNormalUser = true;
      description = "Renderd Service User";
      group = "renderd";
      createHome = true;
      home = "/var/lib/renderd";
      packages = [
        osm2pgsql-runner
        osm-carto-get-fonts
        osm-carto-get-external-data
        osm-prerender-everything
        pkgs.wget
      ];
    };

    systemd.tmpfiles.rules = [
      "d ${renderdShare} 0755 renderd renderd"
      "d ${tileDir} 0755 renderd renderd"
    ];

    systemd.services.renderd = {
      description = "RenderD Daemon";
      wantedBy = [ "multi-user.target" ];
      before = [ "httpd.service" ];
      wants = [ "postgresql.service" ];
      serviceConfig = {
        ExecStart = "${mod_tile}/bin/renderd --config ${renderdConfigFile} --foreground";
        StateDirectory = "renderd";
        User = "renderd";
        WorkingDirectory = renderdShare;
        MemoryHigh = "${builtins.toString cfg.totalRamGb}G";
        MemoryMax = "${builtins.toString cfg.totalRamGb}G";
      };
      environment = lib.optionalAttrs cfg.debug {
        G_MESSAGES_DEBUG = "all";
      };
    };

    services.postgresql = {
      enable = true;
      extraPlugins = [ config.services.postgresql.package.pkgs.postgis ];

      # about the JIT:
      # https://github.com/openstreetmap/mod_tile/issues/181#issuecomment-813253225
      initialScript = builtins.toFile "postgres-initScript" ''
        CREATE ROLE renderd WITH LOGIN SUPERUSER;
        CREATE DATABASE gis;
        GRANT ALL PRIVILEGES ON DATABASE gis TO renderd;

        \c gis;
        CREATE EXTENSION hstore;
        CREATE EXTENSION postgis;
        ALTER TABLE geometry_columns OWNER TO renderd;
        ALTER TABLE spatial_ref_sys OWNER TO renderd;

        ALTER SYSTEM SET jit=off;
        SELECT pg_reload_conf();
      '';
      settings =
        let
          quarterOfTotalMbs = cfg.totalRamGb * 1024 / 4;
          mbStr = x: "${builtins.toString x}MB";
        in
        {
          # https://www.postgresql.org/docs/15/runtime-config-resource.html
          # If you have a dedicated database server with 1GB or more of RAM, a
          # reasonable starting value for shared_buffers is 25% of the memory in
          # your system.
          shared_buffers = mbStr quarterOfTotalMbs;
          work_mem = "256MB";

          #maintenance_work_mem = mbStr quarterOfTotalMbs;
          #autovacuum_work_mem = mbStr (quarterOfTotalMbs / cfg.threads);

          checkpoint_timeout = "10min";
          max_wal_size = "2GB";
        };
    };

    services.httpd = {
      enable = true;
      extraModules = [
        {
          name = "tile";
          path = "${mod_tile}/modules/mod_tile.so";
        }
      ];
      virtualHosts = {
        "tileserver" = {
          documentRoot = "/var/www";
          listen = [{ inherit (cfg) port; }];
          extraConfig = ''
            LoadTileConfigFile ${renderdConfigFile}
            ModTileTileDir ${tileDir}
            ModTileRenderdSocketName ${renderdSocket}

            ModTileEnableStats On
            ModTileRequestTimeout 300
            ModTileMissingRequestTimeout 300
            ModTileMaxLoadOld 16
            ModTileMaxLoadMissing 50

            ModTileCacheDurationMax 604800
            ModTileCacheDurationDirty 90000000
            ModTileCacheDurationMinimum 108000
            ModTileCacheDurationMediumZoom 13 86400
            ModTileCacheDurationLowZoom 9 518400
            ModTileCacheLastModifiedFactor 0.20
            ModTileEnableTileThrottling Off
          '';
        };
      };
    };

    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
