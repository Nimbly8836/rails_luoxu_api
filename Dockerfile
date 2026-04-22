# syntax=docker/dockerfile:1
# check=error=true

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t rails_luoxu_api .
# docker run -d -p 80:80 -e RAILS_MASTER_KEY=<value from config/master.key> --name rails_luoxu_api rails_luoxu_api

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=3.4.5
ARG TDLIB_COMMIT=9b6ff5863
ARG TDLIB_IMAGE=ghcr.io/nimbly8836/rails_luoxu_api-tdlib
ARG TDLIB_IMAGE_TAG=${TDLIB_COMMIT}
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Keep apt metadata in BuildKit cache mounts instead of deleting it every build.
RUN rm -f /etc/apt/apt.conf.d/docker-clean

# Install base packages
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips postgresql-client && \
    (apt-get install --no-install-recommends -y libc++1-18 libc++abi1-18 || \
     apt-get install --no-install-recommends -y libc++1 libc++abi1)

# Set production environment
ENV RAILS_ENV="production" \
    PORT="80" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    SOLID_QUEUE_IN_PUMA="true" \
    SOLID_QUEUE_SUPERVISOR_MODE="async"

FROM ${TDLIB_IMAGE}:${TDLIB_IMAGE_TAG} AS tdlib-runtime

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev libyaml-dev pkg-config

# Install application gems
COPY Gemfile Gemfile.lock ./
RUN --mount=type=cache,target=/usr/local/bundle/cache,sharing=locked \
    bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile --gemfile

# Copy application code
COPY . .
# Use tdlib binary from the dedicated tdlib base image.
COPY --from=tdlib-runtime /libtdjson.so /rails/lib/libtdjson.so

# Precompile bootsnap code for faster boot times
RUN bundle exec bootsnap precompile app/ lib/




# Final stage for app image
FROM base

# Copy built artifacts: gems, application
COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /rails /rails

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    chown -R rails:rails db log storage tmp
USER 1000:1000

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start the production process manager by default, this can be overwritten at runtime
EXPOSE 80
CMD ["bundle", "exec", "foreman", "start", "-f", "Procfile.prod"]
