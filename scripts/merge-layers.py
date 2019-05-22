#!/usr/bin/python3

import argparse
import sys
import os
import tempfile
import json
import hashlib
import tarfile
import datetime


# Parse arguments. We just need the tar file, and the output dir
parser = argparse.ArgumentParser()
parser.add_argument("-i", "--input", help="Input .tar image, from docker save")
parser.add_argument("-o", "--output", help="Output directory; we will save a config.json and layer.tar to it")
parser.add_argument("-p", "--prefix", help="Prefix for each output file")
args = parser.parse_args()

if not (args.input and args.output):
    print("Input and output are required!")
    sys.exit(1)

if not os.path.isfile(args.input):
    print("Input must be a tar file!")
    sys.exit(1)

if not os.path.isdir(args.output):
    print("Output must be a directory!")
    sys.exit(1)

# Output file doesn't have /
args.output = args.output.rstrip('/')

if not args.prefix:
    args.prefix = ""

with tempfile.TemporaryDirectory() as tmpdir:
    if not 0 == os.system("tar -xf %s -C %s" % (args.input, tmpdir)):
        print("Unable to untar saved image")
        sys.exit(1)
    with open("%s/manifest.json" % tmpdir) as manifest_handle:
        manifest = json.load(manifest_handle)
        if not len(manifest) == 1:
            print("Manifest has no entries or more than one entry -- not expected!")
            sys.exit(1)
        manifest = manifest[0]
        # Find the config key
        config_key = "config"
        if not config_key in manifest:
            config_key = "Config" # Try uppercase
        if not config_key in manifest:
            print("Unable to find config key in manifest!")
            sys.exit(1)
        config = manifest[config_key]
        print("Found config: %s" % config)
        # Find each of the layers
        layers_key = "layers"
        if not layers_key in manifest:
            # Try upper
            layers_key = "Layers"
        if not layers_key in manifest:
            print("Unable to find layers in manifest!")
            sys.exit(1)
        layers = [tmpdir + "/" + x for x in  manifest[layers_key]]
        target_dir = "%s/MONOLAYER" % tmpdir
        os.makedirs(target_dir)
        for layer in layers:
          layer_tar = tarfile.open(layer)
          layer_tar.extractall(target_dir)
          layer_tar.close()
        create_tar_cmd = "tar -cf %s/%slayer.tar -C %s ." % (args.output, args.prefix, target_dir)
        if not 0 == os.system(create_tar_cmd):
            print("Cannot create layer tar file!")
            sys.exit(1)
        # Clear up the config file
        with open("%s/%s" % (tmpdir, config)) as config_handle:
          config = json.load(config_handle)
          config.pop("history", None)
          config.pop("parent", None)
          config.pop("rootfs", None)
          # Recompute the layer info
          sha256_hash = hashlib.sha256()
          with open("%s/%slayer.tar" % (args.output, args.prefix),"rb") as layer_handle:
            for byte_block in iter(lambda: layer_handle.read(4096),b""):
              sha256_hash.update(byte_block)
          diff_ids = ["sha256:%s" % sha256_hash.hexdigest()]
          config["rootfs"] = {"type": "layers", "diff_ids": diff_ids}
          config["history"] = [{"created": str(datetime.datetime.utcnow()).replace(' ', 'T') + 'Z', "comment": "image layers flattened and history removed"}]
          with open("%s/%sconfig.json" % (args.output, args.prefix), 'w') as out_config_handle:
            json.dump(config, out_config_handle)
