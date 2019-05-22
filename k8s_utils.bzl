load("@io_bazel_rules_k8s//k8s:object.bzl", "k8s_object")
load("@io_bazel_rules_k8s//k8s:objects.bzl", "k8s_objects")
load("@io_bazel_rules_docker//container:container.bzl", "container_import")
load("@io_bazel_rules_jsonnet//jsonnet:jsonnet.bzl", "jsonnet_library")
load("@io_bazel_rules_jsonnet//jsonnet:jsonnet.bzl", "jsonnet_to_json")

# Very useful helper function if you ever just want to do a docker build, (skrew u bazel and reproducible targets!). 
def docker_build(name, dockerfile, visibility = None):
  native.genrule(
    name = "docker-build-" + name + "-unflattened-genrule",
    srcs = [dockerfile],
	outs = ["docker-build-" + name + "-unflattened.tar"],
	cmd = "cat $(location " + dockerfile + ") | docker build - -t bazel-build-" + name + " && docker save bazel-build-" + name + " -o $@",
	message = "Building image from Dockerfile",
	visibility = ["//visibility:private"]
  )
  native.sh_binary( # Bazel doesn't seem to fully support python3, so we're kinda scuppered and unable to use the py_binary rules
    name = "docker-squasher-" + name, 
    srcs = ["scripts/merge-layers.py"],
    visibility = ["//visibility:private"]
  )
  native.genrule(
    name = "docker-build-" + name + "-squashed-genrule",
    srcs = ["docker-build-" + name + "-unflattened.tar"],
    outs = ["docker-build-" + name + "-config.json", "docker-build-" + name + "-layer.tar"],
    tools = [":docker-squasher-" + name],
    cmd = "./$(location :docker-squasher-" + name + ") --input $(location docker-build-" + name + "-unflattened.tar) --prefix docker-build-" + name + "- --output $(@D)",  
    visibility = ["//visibility:private"],
    message = "Squashing saved image"
  )
  container_import(
    name = name,
    config = "docker-build-" + name + "-config.json",
    layers = ["docker-build-" + name + "-layer.tar"],
    visibility = visibility
  )

# Warning: by default, unusued images are allowed in the images argument, unlike k8s_object. Therefore be careful that there are no typos in the image reference - always test deploy first!
def k8s_jsonnet_object(name, kind, srcs, entrypoint, jsonnet_deps = None, cluster = None, context = None, namespace = None, user = None, kubeconfig = None, substitutions = None, images = {}, image_chroot = None, args = None, visibility = None):
  jsonnet_library(
    name = name + "-jsonnet-lib",
    srcs = srcs,
    deps = jsonnet_deps,
    visibility = ["//visibility:private"]
  )
  jsonnet_to_json(
    name = "gen-" + name + "-spec.json",
    src = entrypoint,
    outs = [name + "-spec.json"],
    deps = [":" + name + "-jsonnet-lib"],
    visibility = ["//visibility:private"]
  )
  k8s_object(
    name = name,
    kind = kind,
    template = name + "-spec.json",
    cluster = cluster,
    context = context,
    namespace = namespace,
    user = user,
    kubeconfig = kubeconfig,
    substitutions = substitutions,
    images = images,
    image_chroot = image_chroot,
    args = args,
    visibility = visibility,
    resolver_args = ["--allow_unused_images"] #Needed since we have the ability to glob out individual components from a larger set of objects
  )

# This encodes a naming convention for generated json spec files
# name_postfix is in order to make the same entrypoing used twice unique
def _spec_file_name(name_postfix, jsonnet_entrypoint):
  if not jsonnet_entrypoint.endswith(".jsonnet"):
    fail("The entrypoint " + jsonnet_entrypoint + " was provided, but entrpoints must all end in .jsonnet!")
  return jsonnet_entrypoint[:-8] + "." + name_postfix + ".spec.json"

# This encodes a naming convention for generated k8s_object targets
def _k8s_object_name(name_postfix, jsonnet_entrypoint): 
  if not jsonnet_entrypoint.endswith(".jsonnet"):
    fail("The entrypoint " + jsonnet_entrypoint + " was provided, but entrpoints must all end in .jsonnet!")
  return jsonnet_entrypoint[:-8] + "." + name_postfix;

# Creates a bunch of k8s_objects based on entrypoints within a jsonnet library that are all of the same type <kind>!
# The names will be derived from their target names, but we will affix a postfix name: so entrypoint file.jsonnet will become file.<name_postfix>.spec.json! e.g. with name dev: static-site.dev.spec.json
# Warning: by default, unusued images are allowed in the images argument, unlike k8s_object. Therefore be careful that there are no typos in the image reference - always test deploy first!
def k8s_jsonnet_objects_of_kind(name_postfix, jsonnet_lib, kind, entrypoints, cluster = None, context = None, namespace = None, user = None, kubeconfig = None, substitutions = None, images = {}, image_chroot = None, visibility = None):
  for entrypoint in entrypoints:
    jsonnet_to_json(
      name = "gen-" + _spec_file_name(name_postfix, entrypoint),
      src = entrypoint,
      outs = [_spec_file_name(name_postfix, entrypoint)],
      deps = [":" + jsonnet_lib],
      visibility = ["//visibility:private"]
    )
    k8s_object(
       name = _k8s_object_name(name_postfix, entrypoint),
       kind = kind,
       template = _spec_file_name(name_postfix, entrypoint),
       cluster = cluster,
       context = context,
       namespace = namespace,
       user = user,
       kubeconfig = kubeconfig,
       substitutions = substitutions,
       images = images,
       image_chroot = image_chroot,
       visibility = visibility,
       resolver_args = ["--allow_unused_images"] #Needed since we have the ability to glob out individual components from a larger set of objects
   )


# A batch rule that defines many targets across resource kinds and components from various globs of sources. A bit of a workhorse!
# Note: unlike k8s_objects, this rule doesn't glue together the output of k8s_jsonnet_object (singular). Rather it takes a list of sources for ingresses, deployments, etc. etc. and glues them together with types, so that the relevant delete, create etc. objects can be defined.
# deployments, replicasets, statefulsets etc. should be entrypoints defined with the <srcs> jsonnet library of the requisite type
# component_labels creates targets that are combinations of entrypoints from deployments, replicasets etc. etc. for quick deployment of a group of different resources that make up a component
# Warning: by default, unusued images are allowed in the images argument, unlike k8s_object. Therefore be careful that there are no typos in the image reference - always test deploy first!
def k8s_jsonnet_objects(name, srcs, pods = [], deployments = [], replicasets = [], statefulsets = [], services = [], ingresses = [], component_labels = {}, jsonnet_deps = None, cluster = None, context = None, namespace = None, user = None, kubeconfig = None, substitutions = None, images = {}, image_chroot = None, visibility = None):
  # Start by making a bit jsonnet lib, as before
  jsonnet_library(
    name = name + "-jsonnet-lib",
    srcs = srcs,
    deps = jsonnet_deps,
    visibility = ["//visibility:private"]
  )
  # Now we make individual k8s_objects for each individual resource
  k8s_jsonnet_objects_of_kind(name, name + "-jsonnet-lib", "Pod", pods, cluster, context, namespace, user, kubeconfig, substitutions, images, image_chroot, visibility)
  k8s_jsonnet_objects_of_kind(name, name + "-jsonnet-lib", "Deployment", deployments, cluster, context, namespace, user, kubeconfig, substitutions, images, image_chroot, visibility)
  k8s_jsonnet_objects_of_kind(name, name + "-jsonnet-lib", "Replicaset", replicasets, cluster, context, namespace, user, kubeconfig, substitutions, images, image_chroot, visibility)
  k8s_jsonnet_objects_of_kind(name, name + "-jsonnet-lib", "Statefulset", statefulsets, cluster, context, namespace, user, kubeconfig, substitutions, images, image_chroot, visibility)
  k8s_jsonnet_objects_of_kind(name, name + "-jsonnet-lib", "Service", services, cluster, context, namespace, user, kubeconfig, substitutions, images, image_chroot, visibility)
  k8s_jsonnet_objects_of_kind(name, name + "-jsonnet-lib", "Ingress", ingresses, cluster, context, namespace, user, kubeconfig, substitutions, images, image_chroot, visibility)
  # Finally we glue together combined k8s_object's for each component
  pfxd_components = {}
  for comp_tag in component_labels:
    pfxd_components[comp_tag + "." + name] = component_labels[comp_tag]
  # Then we do one with *all* resources combined together, just called "name"
  combined_resources = pods + deployments + replicasets + statefulsets + services + ingresses
  pfxd_components[name] = combined_resources
  # Now we loop over each component, and create the glued together object
  for comp_lbl in pfxd_components:
    entrypoints = pfxd_components[comp_lbl]
    for ep in entrypoints:
      if not ep in combined_resources:
        fail("Unable to make component label target for " + comp_lbl + ", the following entrypoint was provided for a component label which is not provided as a resource: " + ep)
    object_names = [":" + _k8s_object_name(name, ep) for ep in entrypoints]
    k8s_objects(
      name = comp_lbl,
      objects = object_names,
      visibility = visibility
    )
  # Done!
