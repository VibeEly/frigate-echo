FROM ruby:3.3

ENV BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_JOBS=4 \
    BUNDLE_RETRY=3

WORKDIR /echo

COPY Gemfile Gemfile.lock ./

RUN bundle install

COPY src ./src

CMD ["bundle", "exec", "ruby", "src/start.rb"]