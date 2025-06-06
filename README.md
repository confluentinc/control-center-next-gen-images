# Docker images for Control Center

This repository is part of the Confluent organization on GitHub.
It is public and open to contributions from the community.

Please see the LICENSE file for contribution terms.
Please see the CHANGELOG.md for details of recent updates.


This repo provides build files for [Control Center](https://www.confluent.io/confluent-control-center/) Docker images.

## Properties

Properties are inherited from a top-level POM. Properties may be overridden on the command line (`-Ddocker.registry=testing.example.com:8080/`), or in a subproject's POM.

- *docker.skip-build*: (Optional) Set to `false` to include Docker images as part of build. Default is 'false'.
- *docker.skip-test*: (Optional) Set to `false` to include Docker image integration tests as part of the build. Requires Python 2.7, `tox`. Default is 'true'.
- *docker.registry*: (Optional) Specify a registry other than `placeholder/`. Used as `DOCKER_REGISTRY` during `docker build` and testing. Trailing `/` is required. Defaults to `placeholder/`.
- *docker.tag*: (Optional) Tag for built images. Used as `DOCKER_TAG` during `docker build` and testing. Defaults to the value of `project.version`.
- *docker.upstream-registry*: (Optional) Registry to pull base images from. Trailing `/` is required. Used as `DOCKER_UPSTREAM_REGISTRY` during `docker build`. Defaults to the value of `docker.registry`.
- *docker.upstream-tag*: (Optional) Use the given tag when pulling base images. Used as `DOCKER_UPSTREAM_TAG` during `docker build`. Defaults to the value of `docker.tag`.
- *docker.test-registry*: (Optional) Registry to pull test dependency images from. Trailing `/` is required. Used as `DOCKER_TEST_REGISTRY` during testing. Defaults to the value of `docker.upstream-registry`.
- *docker.test-tag*: (Optional) Use the given tag when pulling test dependency images. Used as `DOCKER_TEST_TAG` during testing. Defaults to the value of `docker.upstream-tag`.
- *docker.os_type*: (Optional) Specify which operating system to use as the base image by using the Dockerfile with this extension. Valid values are `ubi8`. Default value is `deb8`.
- *CONFLUENT_PACKAGES_REPO*: (Required) Specify the location of the Confluent Platform packages repository. Depending on the type of OS for the image you are building you will need to either provide a Debian or RPM repository. For example this is the repository for the 5.4.0 release of the Debian packages: `https://s3-us-west-2.amazonaws.com/confluent-packages-5.4.0/deb/5.4` This is the repository for the 5.4.0 release of the RPM's: `https://s3-us-west-2.amazonaws.com/confluent-packages-5.4.0/rpm/5.4`
- *C3_VERSION*: (Required) Specify the full C3 release version. Example: 2.0.0


## Building

This project uses `maven-assembly-plugin` and `dockerfile-maven-plugin` to build Docker images via Maven.

To build SNAPSHOT images, configure `.m2/settings.xml` for SNAPSHOT dependencies. These must be available at build time.

```
mvn clean package -Pdocker -DskipTests # Build local images
```

## License

Usage of this image is subject to the license terms of the software contained within. Please refer to Confluent's Docker images documentation [reference](https://docs.confluent.io/platform/current/installation/docker/image-reference.html) for further information. The software to extend and build the custom Docker images is available under the Apache 2.0 License.