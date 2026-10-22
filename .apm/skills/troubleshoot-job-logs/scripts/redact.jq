# 実行ログ・定義を AI に読ませる前に伏せ字にする jq プログラム。redact.sh から呼ばれる。
#
# 既定（allow）: 許可リスト方式。どの顧客でも同じになる文字列（エラー文の一般的な英単語、SQL / HTTP の用語、
#   Java の例外クラス名やスタックトレース、エラーコードらしい形、5 桁以下の数字）だけを残し、
#   それ以外の語（ホスト名・ユーザー名・テーブル名・日本語・長い ID など）は ‹…› に置き換える。
# mask: 個別に許可された範囲を見せるとき用。ホスト名・URL・メール・IP・パス・認証情報らしい値・長い ID を伏せる。
#   許可リストより情報は多く残る（テーブル名や引用符内の語は残りうる）。
# json: 定義の詳細（JSON）用。認証情報らしいキーの値は常に伏せ、列挙値のキーはそのまま、
#   その他の文字列は allow と同じ規則で伏せる。

def vocab: [
  # 英語の機能語・エラー文によく出る語
  "a","an","the","of","to","in","on","at","by","for","from","with","without","into","onto","as","and","or","not","no","nor",
  "is","are","was","were","be","been","being","has","have","had","do","does","did","can","cannot","could","should","would",
  "will","may","might","must","shall","this","that","these","those","it","its","there","here","which","what","when","where",
  "who","why","how","than","then","if","else","but","so","such","only","also","all","any","some","each","every","both",
  "either","neither","one","two","more","most","less","least","other","another","same","due","because","while","after",
  "before","during","until","since","per","via","please","try","again","later","check","see","use","used","using","add",
  "added","remove","removed","exclude","excluded","include","included","convert","converted","option","options","value",
  "values","type","types","column","columns","row","rows","record","records","field","fields","table","tables","schema",
  "schemas","database","databases","dataset","datasets","view","views","index","query","queries","statement","request",
  "requests","response","responses","body","header","headers","parameter","parameters","param","params","argument",
  "arguments","object","objects","file","files","path","paths","directory","folder","bucket","key","keys","id","ids",
  "name","names","user","users","account","accounts","role","roles","permission","permissions","privilege","privileges",
  "access","denied","forbidden","unauthorized","authorized","authentication","authorization","auth","token","tokens",
  "credential","credentials","password","login","logon","session","expired","revoked","invalid","valid","missing",
  "required","unknown","unsupported","supported","support","unexpected","expected","illegal","malformed","bad","wrong",
  "incorrect","failed","failure","fail","fails","error","errors","exception","exceptions","warning","warn","warnings",
  "fatal","info","debug","trace","caused","cause","giving","give","up","retrying","retry","retries","retried","attempt",
  "attempts","timeout","timed","out","time","times","limit","limits","exceeded","exceed","quota","rate","too","many",
  "few","large","small","long","short","size","maximum","max","minimum","min","overflow","out","memory","heap","space",
  "gc","overhead","connection","connections","connect","connected","connecting","refused","reset","closed","close",
  "broken","pipe","host","hostname","port","network","unreachable","route","resolve","resolved","lookup","dns","ssl",
  "tls","handshake","certificate","socket","read","write","written","reading","writing","load","loaded","loading",
  "insert","inserted","update","updated","delete","deleted","merge","upsert","replace","truncate","append","copy",
  "create","created","drop","dropped","alter","exists","exist","existing","already","found","duplicate","duplicated",
  "duplicates","unique","constraint","violation","violates","null","nullable","empty","blank","default","cast","parse",
  "parsing","parsed","format","formatted","encoding","charset","character","characters","invalidated","conversion",
  "number","numeric","string","strings","boolean","date","datetime","timestamp","timezone","zone","utc","jst","json",
  "csv","tsv","xml","parquet","avro","gzip","zip","encrypted","passphrase","provided","private","public","job","jobs",
  "task","tasks","transaction","commit","rollback","done","running","started","start","finished","finish","completed",
  "complete","succeeded","success","successful","status","code","codes","message","messages","detail","details",
  "description","reason","result","results","output","input","preview","guess","plugin","plugins","container",
  "containers","deleting","cleanup","temporary","temp","job_status","api","http","https","get","post","put","patch",
  "head","service","server","client","internal","external","unavailable","available","exhausted","resource",
  "resources","project","consumer","metric","minute","minutes","second","seconds","hour","hours","day","days",
  "oauth","grant","scope","scopes","client_id","refresh","ok","true","false","none","nil","embulk","trocco","sqltype",
  "value_type","column_options","select","from","where","group","order","having","limit","offset","join","left","right",
  "inner","outer","on","union","distinct","as","into","values","set","between","like","case","when","then","end","with",
  "bigquery","snowflake","redshift","databricks","mysql","postgresql","postgres","oracle","sqlserver","mongodb","s3",
  "gcs","sftp","ftp","salesforce","kintone","hubspot","marketo","zendesk","shopify","google","spreadsheets","sheets",
  "drive","ads","analytics","facebook","yahoo","line","tiktok","criteo","jdbc","sql","jruby","ruby","java","raise",
  "raiseexception","ratelimiterror","stack","frames","omitted","common","native","method","thread","worker",
  "executor","pool","run","call","calls","handler","processor","processcookies","responseprocesscookies","cookie",
  "cookies","set-cookie","toplevel","constant","referenced","mutex",
  # 月・曜日・時刻表記（Java のログの日時）
  "jan","feb","mar","apr","may","jun","jul","aug","sep","oct","nov","dec","mon","tue","wed","thu","fri","sat","sun",
  "am","pm","gmt","jst",
  # SQL の型名
  "blob","longblob","mediumblob","tinyblob","binary","varbinary","longvarbinary","geometry","geography","bit","bool",
  "tinyint","smallint","mediumint","int","integer","bigint","decimal","float","double","real","char","varchar","text",
  "longtext","mediumtext","nchar","nvarchar","clob","nclob","time","timestamptz","timestamp_ntz","timestamp_ltz",
  "interval","uuid","variant","array","struct","record","map","enum","year","money","xmltype","raw","rowid"
] | map({(.): true}) | add;

def errword: "^(?:ERROR|ERRORS|EXCEEDED|EXHAUSTED|DENIED|FAILED|FAILURE|INVALID|UNAVAILABLE|NOT|FOUND|LIMIT|TIMEOUT|UNAUTHORIZED|FORBIDDEN|INTERNAL|MISSING|DUPLICATE|DUPLICATES|REQUIRED|EXPIRED|REVOKED|QUOTA|RATE|PERMISSION|UNKNOWN|BAD|REQUEST|ACCESS|SERVICE|RESOURCE|LOGIN|ARGUMENT|VALUE|FIELD|DETECTED|EXISTS|UNSUPPORTED|TOO|MANY|ROW|COLUMN)$";
def javapkg: "^(?:java|javax|jdk|sun|org|com|io|net|scala|kotlin|software|jnr|oracle)$";

# 1 語を許可リストで判定する
def keep_token($v):
  . as $t
  | if ($t | test("^-?[0-9]+$")) then (if ($t | ltrimstr("-") | length) <= 5 then $t else "‹num›" end)
    elif ($t | test("^[^\\x00-\\x7F]+$")) then "‹…›"
    elif ($t | length) <= 2 then $t
    elif ($t | test("^\\$[A-Za-z0-9_]+\\$$")) then $t   # カスタム変数のプレースホルダー（$name$）は設定上の記法なので残す
    elif ($v[$t | ascii_downcase] // false) then $t
    elif ($t | contains(".")) then
      ($t | split(".")) as $s
      | if ($s[-1] | test("^(?:java|rb|scala|kt|class|jar)$")) and ($s[0] | test("^[A-Z]")) then $t
        elif ($s[0] | test(javapkg)) and ($s | any(test("^[A-Z]"))) then $t
        elif ($s | all(test("^[a-z][a-z0-9_]*$") or test("^[A-Z][A-Za-z0-9_]*$"))) and ($s[-1] | test("(?:Exception|Error)s?$")) then $t
        else "‹…›" end
    elif ($t | test("^[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+$")) and ($t | split("_") | any(test(errword))) then $t
    elif ($t | test("^[A-Za-z][A-Za-z0-9]*(?:Exception|Error|Errors|Missing|Denied|Exceeded|Invalid|NotFound|Failed|Failure|Timeout|Unavailable|Expired|Revoked|Required|NotEnabled|Disabled|Forbidden|Unauthorized)$")) then $t
    elif ($t | test("^[a-z]+(?:_[a-z]+)+$")) and ($t | split("_") | any(test("^(?:invalid|denied|expired|revoked|missing|required|exceeded|error|failed|unauthorized|forbidden|insufficient|not|limit|rate|quota|timeout|unavailable|grant|scope|permission)$"))) then $t
    else "‹…›" end;

def allow_text($v):
  gsub("(?<t>[A-Za-z_$][A-Za-z0-9_$-]*(?:\\.[A-Za-z_$][A-Za-z0-9_$-]*)*|-?[0-9]+|[^\\x00-\\x7F]+)"; .t | keep_token($v));

def mask_text:
  gsub("(?i)(?<k>set-cookie|cookie)(?<s>\\s*:\\s*).*$"; "\(.k)\(.s)‹secret›")
  | gsub("(?i)(?<k>password|passwd|pwd|passphrase|token|secret|api[_-]?key|access[_-]?key|authorization|private[_-]?key)(?<s>[\"']?\\s*[:=]\\s*[\"']?)(?<v>[^\\s\"',}]+)"; "\(.k)\(.s)‹secret›")
  | gsub("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"; "‹email›")
  | gsub("(?<sch>[A-Za-z][A-Za-z0-9+.-]*)://[^\\s'\"<>)]+"; "\(.sch)://‹url›")
  | gsub("\\b(?:[0-9]{1,3}\\.){3}[0-9]{1,3}\\b"; "‹ip›")
  | gsub("(?:/[^\\s/:'\"(),]+){2,}"; "‹path›")
  # Java のパッケージ名（org.embulk.input.http.HttpException）は直後にクラス名が続くので除く
  | gsub("\\b[a-z0-9-]+(?:\\.[a-z0-9-]+)+\\.[a-z]{2,}\\b(?!\\.[A-Za-z0-9_])"; "‹host›")
  # Cookie やトークンらしい長い文字列（英字と数字が混ざる）。長いだけの識別子（organization_memberships）は残す
  | gsub("(?=[A-Za-z0-9+/=_-]*[0-9])(?=[A-Za-z0-9+/=_-]*[A-Za-z])[A-Za-z0-9+/=_-]{24,}"; "‹token›")
  | gsub("(?<![0-9])[0-9]{6,}(?![0-9])"; "‹num›");

def secret_key: "(?i)(?:^|_)(?:token|tokens|password|passphrase|secret|secrets|api_key|apikey|private_key|access_key|secret_key|auth|authorization|header|headers|cookie|cookies|credential|credentials)$";
def enum_key: "^(?:mode|write_disposition|method|query_mode|on_matched_action|schema_evolution_mode|frequency|time_zone|charset|pager_type|success_code|type|destination_type|notify_when|notification_type|status|executor_type|input_option_type|output_option_type|location|default_time_zone|newline|compression|format)$|_(?:type|mode)$";

def redact_json($v):
  reduce paths(scalars) as $p (.;
    ([$p[] | strings] | last // "") as $k
    | getpath($p) as $x
    | if ($x | type) == "string" then
        if ($k | test(secret_key)) then setpath($p; "‹secret›")
        elif ($k | test(enum_key)) and ($x | length) <= 40 then .
        else setpath($p; $x | allow_text($v)) end
      elif ($x | type) == "number" and (($x | fabs) >= 100000) then setpath($p; "‹num›")
      else . end);

# 入力: allow / mask はファイル全体を 1 つの文字列（jq -Rs）、json は JSON。
# 行番号は元ファイルと同じに保つ（伏せ字にしても行は消さない）。mask は $start〜$end 行だけを出す。
vocab as $v
| if $mode == "allow" then
    split("\n") | to_entries | map("\(.key + 1)\t\(.value | allow_text($v))") | join("\n")
  elif $mode == "mask" then
    split("\n") | to_entries
    | map(select(.key + 1 >= ($start | tonumber) and .key + 1 <= ($end | tonumber)))
    | map("\(.key + 1)\t\(.value | mask_text)") | join("\n")
  elif $mode == "json" then redact_json($v)
  else error("unknown mode: \($mode)") end
