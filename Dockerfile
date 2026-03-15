# syntax=docker/dockerfile:1
# check=error=true

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t rails_luoxu_api .
# docker run -d -p 80:80 -e RAILS_MASTER_KEY=<value from config/master.key> --name rails_luoxu_api rails_luoxu_api

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=3.4.5
ARG TDLIB_COMMIT=9b6ff5863
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips postgresql-client && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development"

# Build TDLib from source and export libtdjson.so (cache-friendly stage).
FROM base AS tdlib-build
ARG TDLIB_COMMIT

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      ca-certificates \
      cmake \
      git \
      gperf \
      libssl-dev \
      make \
      php-cli \
      zlib1g-dev && \
    (apt-get install --no-install-recommends -y clang-18 libc++-18-dev libc++abi-18-dev libc++1-18 libc++abi1-18 || \
     apt-get install --no-install-recommends -y clang libc++-dev libc++abi-dev libc++1 libc++abi1) && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

RUN set -eux; \
    git clone https://github.com/tdlib/td.git /tmp/td; \
    cd /tmp/td; \
    git checkout "${TDLIB_COMMIT}"; \
    rm -rf build; \
    mkdir build; \
    cd build; \
    cc_bin="$(command -v clang-18 || command -v clang)"; \
    cxx_bin="$(command -v clang++-18 || command -v clang++)"; \
    CXXFLAGS="-stdlib=libc++" \
    CC="${cc_bin}" \
    CXX="${cxx_bin}" \
    cmake -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_INSTALL_PREFIX:PATH=../tdlib \
          ..; \
    cmake --build . --target tdjson -j"$(nproc)"; \
    lib_file="$(find . -type f -name 'libtdjson.so' | head -n1)"; \
    if [ -z "${lib_file}" ]; then \
      lib_file="$(find . -type f -name 'libtdjson.so.*' | sort -V | tail -n1)"; \
    fi; \
    test -n "${lib_file}"; \
    install -Dm755 "${lib_file}" /out/libtdjson.so; \
    mkdir -p /out/deps; \
    for name in libc++.so.1 libc++abi.so.1 libunwind.so.1; do \
      dep="$(find /usr/lib /usr/lib64 /lib /lib64 -type f -name "${name}" | head -n1 || true)"; \
      if [ -n "${dep}" ]; then cp -v "${dep}" /out/deps/; fi; \
    done; \
    test -f /out/deps/libc++.so.1; \
    test -f /out/deps/libc++abi.so.1; \
    ls -l /out/deps || true; \
    ls -l /out/libtdjson.so

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile --gemfile

# Copy application code
COPY . .
# Use tdlib binary compiled in tdlib-build stage.
COPY --from=tdlib-build /out/libtdjson.so /rails/lib/libtdjson.so

# Precompile bootsnap code for faster boot times
RUN bundle exec bootsnap precompile app/ lib/




# Final stage for app image
FROM base

# Copy built artifacts: gems, application
COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /rails /rails
COPY --from=tdlib-build /out/deps/ /usr/local/lib/tdlib-deps/

# Make tdlib runtime deps globally discoverable by dynamic linker.
RUN set -eux; \
    if [ -d /usr/local/lib/tdlib-deps ]; then \
      cp -av /usr/local/lib/tdlib-deps/. /usr/local/lib/; \
    fi; \
    ldconfig || true

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    chown -R rails:rails db log storage tmp
USER 1000:1000

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start server via Thruster by default, this can be overwritten at runtime
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
