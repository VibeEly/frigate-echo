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

CMD ["bundle", "exec", "ruby", "src/start.rb"]