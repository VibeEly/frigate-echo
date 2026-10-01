FROM ruby:3.3
 
ENV BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_JOBS=4 \
    BUNDLE_RETRY=3
 
# rsync + an ssh client are required for the remote backup feature
RUN apt-get update \
    && apt-get install -y --no-install-recommends rsync openssh-client \
    && rm -rf /var/lib/apt/lists/*
 
WORKDIR /echo
 
COPY Gemfile Gemfile.lock ./
 
RUN bundle install
 
COPY src ./src
 
# Healthy = the app has touched /tmp/healthy within the last 2 minutes
# It does so every 15s while connected to MQTT
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD test -n "$(find /tmp/healthy -mmin -2 2>/dev/null)" || exit 1
 
CMD ["bundle", "exec", "ruby", "src/start.rb"]