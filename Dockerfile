FROM ruby:3.1.4

RUN apt-get update && apt-get install -y \
  cmake \
  build-essential \
  libssl-dev \
  pkg-config \
  git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock ghtorrent.gemspec ./

RUN bundle install

COPY . .

EXPOSE 4567

CMD ["ruby", "app.rb"]
