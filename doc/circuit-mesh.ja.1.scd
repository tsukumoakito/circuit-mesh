circuit-mesh(1) "1.0.7" "circuit-mesh ユーザマニュアル"

# 名前

circuit-mesh - Zig、Netlink、Tor を活用したゼロトラスト・ネットワークエンジン

# 書式

*circuit-mesh* [オプション...]

# 説明

*circuit-mesh* は、ゼロトラストな出口ポリシーを強制するために設計された高性能なネット
ワークセキュリティエンジンです。Linux カーネルの *IPSet* バリアを *Netlink* を介し
て動的に同期し、DNS 通信を隔離された Tor 回路にトンネリングすることで動作します。

このエンジンは、自動化されたアイデンティティ回転機能を備えた堅牢な DNS-over-TLS
(DoT) および DNS-over-HTTPS (DoH) サービスを提供しつつ、システム全体のネットワー
クアクセスを信頼されたノード（Tor のディレクトリオーソリティおよびガードノード）
のみに制限することを保証します。

# オプション

*--config* <path>
	JSON 設定ファイルのパスを指定します。デフォルトは
	*/etc/circuit-mesh/config.json* です。

*--debug*
	詳細なテレメトリを有効にします。Netlink バリアの同期、Tor 回路の状態、および
	トンネルの健全性指標に関するリアルタイムログを提供します。

# 設定 (JSON)

設定ファイルは、ネットワークバリアと暗号化トンネルの挙動を定義します。以下は主要な
トップレベルキーの説明です。

*ipset_name* (string)
	管理対象となる IPSet の名称。*circuit-mesh* は IPv6 セットに対して自動的に
	'6' を付加します（例: "BOOTSTRAP" と "BOOTSTRAP6"）。

*monitoring_interval_ms* (integer)
	Netlink エンジンが Tor ノードの可用性を検証する頻度（ミリ秒単位）。

*cold_start_doh_enabled* (boolean)
	true の場合、起動時に Tor が完全に動作していない状態でも、直接 DoH を使用し
	たブートストラップを許可します。

*doh_fallback_allowed* (boolean)
	true の場合、すべての Tor トンネルが失敗した際の予備ルートとして、直接の
	DoH 接続を許可します。

*global_settings*
	- *max_concurrent_rotations*: 同時にアイデンティティ回転を行うトンネルの最
	  大数。
	- *rotation_check_interval_s*: ウォッチドッグによる内部ヘルスチェックの頻
	  度。

*tor_global*
	Tor との連携設定。IP 検出と回路のパージに必要です。
	- *socks_ip*, *socks_port*: トンネル用 SOCKS5 リスナ。
	- *control_ip*, *control_port*: Tor ControlPort へのアクセス設定。
	- *cookie_path*: Tor の *control_auth_cookie* へのパス。
	- *binary_path*: ハードコードされた IP 抽出用の Tor バイナリへのパス。
	- *state_path*, *consensus_path*: ガードノードの IP を解決するための Tor
	  内部状態ファイルへのパス。

*dns_tunnels* (array)
	ローカル DNS リスナの定義。
	- *name*: ログ出力用の識別子。
	- *ip*: リモート DNS サーバの IP（例: "1.1.1.1"）。
	- *sni*: TLS/HTTPS 通信用の Server Name Indication。
	- *local_ip*, *local_port*: 待機するローカルインターフェースとポート。

*rotation_profiles* (array)
	アイデンティティの TTL（生存期間）範囲の定義。*min_ttl* と *max_ttl* の間で
	ランダムなジッターが適用されます。

# セキュリティ

*circuit-mesh* は、Netlink サブシステムとやり取りするために *CAP_NET_ADMIN* およ
び *CAP_NET_RAW* ケーパビリティを必要とします。バイナリを *root* として実行するか、
適切なアンビエントケーパビリティを付与した systemd ユニット経由で実行することを推
奨します。

*IPSet* バリアは、明示的に許可されていないすべての通信を事実上遮断します。
*tor_global* のパス設定を誤ると、起動時の検出フェーズで有効な Tor エントリポイン
トを見つけられず、ネットワーク全体がロックアウトされる可能性があります。

# ファイル

*/etc/circuit-mesh/config.json*
	デフォルトの設定ファイル配置場所。

# 終了ステータス

*0*
	成功。

*1*
	失敗（例: 不正な設定、権限不足、または Netlink 通信エラー）。

# 著者

TSUKUMO Akito <tsukumoakito99@duck.com> によって開発されました。

# ライセンス

AGPL-3.0-or-later とコマーシャル・ライセンスのデュアルライセンスの下で提供されて
います。
