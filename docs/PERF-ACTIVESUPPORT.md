# Active Support 8.1 での sabaku と mutant の比較

> 測定日 2026-11-18。対象は rails/rails v8.1.4.1 (commit 3f290b7) の activesupport。件数と score は error 分類と初回ロード再試行を入れた後に取り直した 1 回の値、wall は修正前の交互実行の中央値と、再試行を入れた後の 1 回の実測である。

## 結論

同じ 23,790 行の範囲を、同じスイート、同じ jobs、同じ timeout で回した。全深さでは sabaku が 534.3 秒、mutant 0.17.1 が 1,584.5 秒で、sabaku が 3.0 倍速い。mutation 数を揃えた 1 mutation あたりの wall は 14.9ms 対 53.9ms で、coverage 収集の固定費 76 秒を除くと 12.7ms 対 53.9ms になる。この 12.7ms には初回ロード再試行の 55 秒も含む。

差はテスト実行ではなく、mutation の生成と管理の側で出る。mutant は 29,386 mutation の生成とスケジューリングに wall の大半を使い、テスト実行の総和 (killtime) は 829 秒から 851 秒で 8 並列に収まる。sabaku はテスト選択のための coverage 収集に 76 秒を固定で払い、あとは 1 mutant あたり約 12.7ms で進む。

| エンジン | 深さ | mutation 数 | wall (中央値) | 1 mutation あたり | killed | survived | timeout | uncovered | skipped | error | score |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| sabaku | `--per-line=1` (既定) | 5,334 | 146.8s (再試行あり, n=1) | 27.5ms | 3,464 | 696 | 214 | 931 | 29 | 0 | 79.20% |
| sabaku | `--per-line=all` | 35,986 | 534.3s (再試行あり, n=1) | 14.9ms | 24,211 | 4,296 | 1,350 | 5,944 | 185 | 0 | 81.09% |
| mutant | 既定 (operators light) | 29,386 | 1,584.5s (1,505.6 から 1,663.3, n=2) | 53.9ms | 23,837 から 23,854 | 4,299 から 4,327 | 1,205 から 1,250 | 0 | 0 | 0 | 81.11 から 81.17% |

表の killed から score は分類修正と初回ロード再試行を入れた後の値である。分類修正だけを入れた時点の wall は 135.7 秒と 479.5 秒で、中央値より 2% から 3.5% 長かった。再試行を足すと 146.8 秒と 534.3 秒になり、その時点から 8% と 11% 伸びる。再試行は 118 件と 754 件の fresh process で、1 件あたり約 0.9 秒、8 並列で 13 秒と 55 秒に相当する。どちらも 1 回ずつの測定なので、ホスト負荷の幅はこの差より小さいとは限らない。

全深さの score が 81.09% と 81.11 から 81.17% で揃っているのは、同じスイートに対して「生き残った割合」が同じという意味である。見つけたテスト穴の一覧が同じという意味ではない。

## 対象と範囲

| 項目 | 値 |
| --- | --- |
| 対象 | rails/rails v8.1.4.1 の activesupport |
| lib | 289 ファイル、31,501 行 |
| 比較範囲 | ActiveSupport 名前空間。171 ファイル、23,790 行。core_ext 7,711 行は両者から除外 |
| テスト | 5,778 件、0 failures、0 errors、62 skips |
| スイート実行時間 | 直列 67.6 秒 (1 回実測) |
| Ruby | 3.4.12 |
| minitest | 6.1.0 (Rails 8.1 の Gemfile に合わせる) |
| mutant | 0.17.1 と mutant-minitest 0.17.1 |
| ホスト | 20 コア、31GB、共有マシン、load average 1.4 から 4.7 |
| 実行環境 | dev コンテナ、`SABAKU_NO_CACHE=1`、キャッシュファイルは毎回削除 |

core_ext を外したのは、mutant の subject 式 `ActiveSupport*` が core クラスへの monkeypatch を拾わないためである。mutant 側は `lib/active_support/core_ext` に定義された ActiveSupport 名前空間の subject 6 件 (235 mutation、全体の 0.8%) を残しているので、範囲は完全には一致しない。

## 計測方法

外側の wall はコンテナ内の `date +%s%N` で測り、コンテナ起動は含めない。両者とも `--jobs=8`、timeout 1 秒、テスト選択は既定 (sabaku は coverage ベース、mutant は context_map)、operators は既定で固定した。m1, a1, c1, m2, a2, c2, a3 の順でエンジンを交互に並べ、各実行の前にキャッシュを消した。分類修正後の再測は、同じコマンドを既定と全深さで 1 回ずつ、こちらの他の実行を止めた状態で回した。

mutant のテスト選択には simplecov 1.3.2 の `track_tests` で作った `coverage/coverage.json` を使った。記録は 3,383 test context、line coverage 94.86%。選択テストは 5,712 件で、subject あたり 7.34 件。

mutant を動かすには二つの前提が要る。一つは `-r abstract_unit` より前に `mutant/minitest` を require すること。逆順だと minitest の at_exit が先に登録され、fork した子のテスト結果が常に passed 扱いになり、alive を量産する。もう一つは subject 名に `%` を含む 3 件 (`ActiveSupport::Duration#%`、`ActiveSupport::Duration::Scalar#%`、`ActiveSupport::SafeBuffer#%`) を `--ignore-subject` で外すこと。0.17.1 の reporter は subject 名を format 文字列として扱うため、`%` があると `ArgumentError: malformed format string` で落ちる。

sabaku は `--no-baseline` で回した。スイート自体は緑だが、`BacktraceCleanerCleanLocationsTest` の 2 件が 1 テストずつ実行すると `caller_locations` の形が変わって落ちる。この 2 件が覆う `lib/active_support/backtrace_cleaner.rb` は両者の範囲から外してあるので、比較対象の mutation には影響しない。

## 差の内訳

sabaku の固定費は coverage 収集の約 76 秒である。これは 5,778 テストを 1 件ずつ実行して行ごとの到達を記録する時間で、coverage 収集だけを走らせた実行の 76.7 秒から取った。既定の 133.2 秒のうち 57%、全深さの 463.1 秒のうち 16% を占める。差し引いた 1 mutation あたりは 10.7ms と 10.8ms で、深さを変えても同じだった。

mutant は自身の集計を出す。m1 は runtime 1,462 秒、killtime 851 秒、m2 は runtime 1,620 秒、killtime 829 秒。killtime はテスト実行時間の総和で、8 並列なので wall への寄与は約 105 秒である。残りの約 1,300 秒から 1,500 秒が mutation の生成、fork、結果の集約、alive 5,500 件の diff 出力に使われている。timeout 1 秒に当たった mutation が 1,205 件から 1,250 件あり、その待ちも killtime に含まれる。

つまり両者の律速は別である。mutant は mutation を 1 件ずつ生成して回す直列部分、sabaku は最初の coverage 収集と、fork した子での短いテスト実行である。並列度を上げても mutant の wall は生成側で頭打ちになる。

## error の分類

最初の計測では error が 154 件 (全深さ 978 件) 出た。実行時のメッセージと、無変異のファイルを同じ子の形でもう一度評価する対照実験で分けると、原因は三つだった。分類修正で error は 0 件になり、続けて初回ロードの再試行を入れると skipped は 29 件 (同 185 件) まで減った。

| 原因 | 既定 | 全深さ | 扱い |
| --- | ---: | ---: | --- |
| ファイルが fork isolation で再読み込みできない | 129 | 813 | 初回ロードで再試行。118 / 754 が実測、11 / 59 が skipped |
| 変異そのものがファイルをロードできない | 18 | 126 | skipped (not measured) |
| テスト中に子が結果を書けずに落ちた | 7 | 39 | killed |

一つ目はハーネスの性質である。子は親がロード済みのファイルを丸ごと評価し直すので、`undef` を二度実行する `hash_with_indifferent_access.rb` (90 件)、ロード時の deprecation 警告が :raise で例外になる `configurable.rb` (21 件)、テスト実行後の Subscriber の状態で `method_added` が落ちる `structured_event_subscriber.rb` (18 件) は、変異と無関係に落ちる。この 129 件は、変異を最初のロード時に当てる面で測り直した。二つ目は `Editor` の `register` 呼び出しのようなクラス本文の文を壊す変異で、変異を当てたファイルがロードできない。これはテストが 1 件も走らないまま skipped になる。

三つ目の 7 件は、テスト中に子が落ちたもので、原因はさらに割れる。5 件は `abstract_unit.rb` の `Thread.abort_on_exception = true` により、テストが起こしたスレッドの例外が子プロセスを exit 1 にしたもの。1 件は例外メッセージが UTF-8 でないバイト列を含み、子から親への JSON 1 行が書けなかったもの (`transliterate.rb:74`)。1 件はテストクラスが `run` を上書きして `Minitest::Result` 以外を返し、アダプタがその戻り値の `passed?` を呼んだもの (`testing/isolation.rb:32`)。

再試行の面は fresh process である。スイートを通常の順序でロードし、プロジェクトがターゲットを require か autoload した瞬間に変異ソースを評価する。`configurable.rb` は冒頭で `ActiveSupport.deprecator` を呼ぶので、変異ファイルを最初に単独で評価する方式では `NameError` になる。プロジェクトを先にロードし、ロードの位置で変異を当てる必要がある。この面で 118 件 (同 754 件) が killed か survived か timeout になった。残る 11 件 (同 59 件) は、変異を当てたファイルをテストファイルがクラス本文で使っていて、スイート自体がロードできないものである。

直したのはハーネス側の三箇所である。再読み込みの対照実験で 129 件と 18 件を原因別の skipped にした。`describe_exception` はメッセージを UTF-8 に scrub し、JSON の失敗で結果を失わないようにした。アダプタは 1 テストの例外をそのテストの失敗として返し、子を落とさないようにした。残る 5 件は exit 1 を「選択テストが失敗した」という既存の契約どおり killed に数える。

skipped は score の分母に入らない。mutant は fresh process でファイルを 1 回だけロードするのでこの制約がなく、sabaku が測れなかったファイルの mutant も測れている。

## 公平性の確認

- テストは両者とも同じ 5,778 件を読み、同じ環境で動かした。mutant の選択テストは 5,712 件で 0 件ではない。
- mutant が kill を検出できることは、別の小さなプロジェクト (10 mutation) で 10 件とも killed になることを確認した。
- sabaku の error は 0 件。未測定は 29 件 (同 185 件、0.5%) で、内訳は変異自体がロードできない 18 件 (同 126 件) と、初回ロードでもスイートがロードできない 11 件 (同 59 件) である。mutant 側の error は 0 件で、fresh process で 1 回だけロードするため、sabaku が測れなかったファイルの mutant も測れている。この 0.5% は sabaku の score に有利に働く。
- timeout 1 秒は両者に同じだけ効いている。sabaku は 214 件と 1,350 件、mutant は 1,205 件と 1,250 件。
- 範囲の重なりは 99.2%。mutant だけが持つ core_ext 由来の 235 mutation は wall の差を mutant に不利にしている側で、最大でも 1% 程度である。
- operator の集合は違う。mutant は light、sabaku は 14 種で、全深さでも mutation 数は 35,986 対 29,386 と 1.22 倍違う。したがって score の比較は品質の判定ではなく、同じスイートに対する生存率の一致確認である。

## 再現

```sh
# 1. 対象を取得
git clone --depth 1 --branch v8.1.4.1 --filter=blob:none --sparse https://github.com/rails/rails
cd rails && git sparse-checkout set activesupport railties tools

# 2. イメージを作る。sabaku:mutant は ruby:3.4-slim に mutant 0.17.1 と
#    mutant-minitest を入れたもの。ビルドの作業ディレクトリは sabaku のリポジトリ。
docker build -t sabaku:as -f - . <<'EOF'
FROM sabaku:mutant
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends tzdata tzdata-legacy build-essential
RUN gem install --no-document i18n tzinfo concurrent-ruby connection_pool 'dalli:<5' redis minitest-mock msgpack builder rexml listen rack
RUN gem install --no-document json -v 2.15.1
COPY . /opt/sabaku
RUN cd /opt/sabaku && gem build -q sabaku.gemspec && gem install --no-document sabaku-0.1.0.gem
EOF

# 3. mutation を実行 (cwd は activesupport)
#    RUBYOPT には minitest-mock の有効化と、mutant 用の先行 require を置く
sabaku run lib/active_support.rb lib/active_support --per-line=all \
  --exclude='lib/active_support/core_ext/**/*.rb' \
  --exclude='lib/active_support/backtrace_cleaner.rb' \
  --no-baseline --jobs=8 --timeout=1 --report=json --output=/tmp/rm.json

mutant run --integration minitest --selection context_map --selection-path coverage/coverage.json \
  -Ilib -Itest -I../railties/lib -r abstract_unit -j 8 -t 1 --usage opensource \
  --ignore-subject 'ActiveSupport::Duration#%' \
  --ignore-subject 'ActiveSupport::Duration::Scalar#%' \
  --ignore-subject 'ActiveSupport::SafeBuffer#%' \
  --ignore-subject 'ActiveSupport::BacktraceCleaner*' \
  'ActiveSupport*'
```

## 限界

- mutant の実行は 2 回で 1,505.6 秒と 1,663.3 秒、幅は 10.5% ある。sabaku の幅は 2.3% 以下である。共有ホストの負荷とページキャッシュの状態が効いている可能性がある。表の中央値は 2 回の平均で、幅より大きく出た 3.4 倍の差はこの 2 回でも再現しているが、mutant 側は 1 回の測定として読むのが安全である。
- timeout 1 秒は、遅いテストを含む mutation を timeout として打ち切る。timeout 5 秒にすると両者とも wall が伸び、差の比率は変わる。
- mutant の生成とテスト実行の切り分けは、自身が出力する runtime と killtime に依存する。プロファイラでの分解はしていない。
- sabaku は初回ロードでも測れない mutant を skipped として score の分母から外す (既定 29 件、全深さ 185 件、0.5%)。mutant は全件を測れているので、score の比較は sabaku に有利な側にこの未測定を残している。
- sabaku は被覆のない行の mutant を uncovered として実行しない (全深さで 5,944 件、16.5%)。mutant は被覆に関係なく全 mutation を回す。この分だけ作業の内訳が違う。
- 対象は ActiveSupport 1 つである。他の大規模プロジェクトで同じ比率になるとは限らない。
