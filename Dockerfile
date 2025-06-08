FROM ruby:3.1.4

RUN apt-get update && apt-get install -y \
  cmake \
  build-essential \
  libssl-dev \
  pkg-config \
  git \
  supervisor \
  redis-tools \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock ghtorrent.gemspec ./

RUN bundle install

COPY . .

COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

EXPOSE 4567

# CMD ["ruby", "app.rb"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]