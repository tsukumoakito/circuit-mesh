<!--
SPDX-FileCopyrightText: 2026 TSUKUMO Akito <tsukumoakito99@duck.com>
SPDX-License-Identifier: AGPL-3.0-or-later OR LicenseRef-circuit-mesh-Commercial
-->

# Circuit Mesh テクニカルマニュアル (v1.0.1 / 2026-09-05)

`Circuit Mesh` は、ゼロトラスト・ネットワーク・ゲートキーパーです。本書では、その設定スキーマ、回転ロジック、および実装の詳細について詳細に解説します。

---

## 1. コアアーキテクチャ

本エンジンは、以下のステートマシンに基づいて動作します：

1. **ブートストラップ**: ファイルシステムをスキャンし、信頼された IP アドレスを特定します。
2. **バリアの強制**: Netlink を介して Linux カーネルの `IPSet` を更新します。
3. **カプセル化**: ローカルの DNS トラフィックを遮断し、隔離された Tor 回路へトンネリングします。
4. **アイデンティティの移行**: 出口 IP の多様性を確保するため、SOCKS 認証情報を回転（ローテーション）させます。

---

## 2. 設定リファレンス (`config.json`)

### 2.1. ルートパラメータ

- **`ipset_name`** (String): カーネル IPSet のベース名称。
    - *仕組み*: `circuit-mesh` は 2 つのセットを管理します。例えば `BOOTSTRAP` に設定した場合、`BOOTSTRAP` (IPv4) と `BOOTSTRAP6` (IPv6) を扱います。
- **`monitoring_interval_ms`** (Integer): Netlink 同期ループ間の待機時間。
- **`cold_start_doh_enabled`** (Boolean): 有効な場合、起動後の最初の 60 秒間に Tor ControlPort に接続できないとき、直接 DoH（Tor を回避）でクエリを送信します。
- **`doh_fallback_allowed`** (Boolean): 実行中に Tor への接続が失われた場合、システムの可用性を維持するために直接的な HTTPS トンネリングにフォールバックします。

### 2.2. `tor_global` (ディスカバリ・ロジック)

このセクションでは、バリアに登録する「信頼された IP」をエンジンがどのように検出するかを定義します。

- **`cookie_path`**: Tor の `control_auth_cookie` へのパス。ControlPort 認証に必要です。
- **`binary_path`**: エンジンは Tor の実行バイナリをスキャンし、ハードコードされた Directory Authority (DA) の IP アドレスを抽出します（`orport=` パターンのスキャン）。
- **`state_path`** / **`consensus_path`**: Tor の内部ディスクリプタをスキャンし、現在アクティブなガードノードの IP アドレスを解決します。

### 2.3. `rotation_profiles` (ジッター計算)

単一の Tor アイデンティティ（SOCKS ユーザー名/パスワードのペア）のライフサイクルを定義します。

- **ロジック**: パターン解析を防ぐため、生存期間 (TTL) は以下の式を用いて算出されます：
    `Next_Rotation（次回回転） = 現在時刻 + min_ttl + random(0, max_ttl - min_ttl)`
- **`name`**: プロファイルをサービスに紐付けるために使用されます（例: "dns"）。

### 2.4. `dns_tunnels` (トンネル実装)

各エントリは、DNS クエリを暗号化トンネルにラップするローカルリスナを生成します。

- **`sni`**: TLS ハンドシェイクにおいて重要です。リモート DNS プロバイダの証明書と一致する必要があります。
- **実装の違い**:
    - **DoT (DNS over TLS)**: **Zig ネイティブ TLS** を使用します。Tor がオンラインの際に使用される、プライマリな高性能ルートです。
    - **DoH (DNS over HTTPS)**: **OpenSSL + 手動 H2 フレーミング** を使用します。これは「コールドスタート」および「フォールバック」シナリオで使用され、ディープ・パケット・インスペクション (DPI) やプロキシの干渉に対してより高い耐性を持ちます。

---

## 3. 実装の詳細

### 3.1. アイデンティティ回転と回路のパージ

TTL の満了または失敗しきい値によって回転がトリガーされると、以下の動作を行います：

1. 新しいランダムな 64 文字の SOCKS5 ユーザー名/パスワードのペアが生成されます。
2. 新しいアイデンティティを使用してプローブクエリ（疎通確認）が送信されます。
3. 成功すると、古いアイデンティティにパージ（削除）フラグが立てられます。
4. `circuit-mesh` は Tor ControlPort に対して特定の `SOCKS_USERNAME` を指定した `CLOSECIRCUIT` コマンドを送信し、古い回路が物理的に破棄されることを確実にします。

### 3.2. Netlink エンジン

`ipset` コマンドのシェルスクリプト・ラッパーとは異なり、`circuit-mesh` は生の Netlink ソケット (`AF_NETLINK`) を使用してカーネルと直接通信します。

- **安全性**: プログラムがクラッシュした場合でも、IPSet はカーネル内に残り、ロック状態が維持されます。
- **原子的な更新**: `NLM_F_ACK` を使用し、カーネルがバリアルールを正常に適用したことを確認してから処理を続行します。

---

## 4. ロードマップ

`config.json` 内の以下のセクションは、現在スキーマとしては定義されていますが、コアロジックにはまだ完全には実装されていません：

- **`email_providers`**: プロバイダごとのアイデンティティ回転を備えた、隔離された IMAP/SMTP プロキシのサポート。
- **`proxy_groups`**: 汎用的な SOCKS/HTTP プロキシチェーン（例：I2P や VPN との統合）。
- **Zig 0.16.0 への移行**: ビルド時の安全性を向上させるため、次期 Zig コンパイラリリースをサポートするためのリファクタリング。

---

## 5. デプロイ例

```json
{
  "ipset_name": "TRUSTED_NODES",
  "dns_tunnels": [
    {
      "name": "Cloudflare-Tor",
      "ip": "1.1.1.1",
      "sni": "one.one.one.one",
      "local_ip": "127.0.0.1",
      "local_port": 5300
    }
  ],
  "rotation_profiles": [
    { "name": "dns", "min_ttl": 600, "max_ttl": 1200 }
  ]
}
```

*注意: ターミナルで `circuit-mesh --debug` を実行すると、これらのパラメータのリアルタイムな計算結果を確認できます。*
