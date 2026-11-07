# WooorkFlip (GUI)
Windows上で開いているアプリケーションのウィンドウ配置を保存し、後から復元するためのツールです。


## 注意点
* AIを活用しながら開発したアプリです。
* 私自身が使用することを目的としているため、十分な動作検証やエラーへの対応ができていない部分があります。
* ご利用の環境によっては、正常に動作しない場合があります。
上記をご理解のうえ、ご利用ください。

## 動作環境

- Windows 10 / 11
- **PowerShell 7**

※ Windows標準のWindows PowerShell 5.1ではなく、PowerShell 7（`pwsh.exe`）を使用してください。

## 起動方法

### GUIの起動

WooorkFlipのフォルダーにある起動用ファイルを実行します。

PowerShell 7から直接起動する場合は、以下のコマンドを使用します。

```powershell
pwsh -NoProfile -STA -File .\WooorkFlip-GUI.ps1
```

GUIが表示されれば起動完了です。

※ `-STA` はWPFによるGUIの動作に必要な起動オプションです。

## 基本操作

### Save（保存）

現在開いているウィンドウの配置をWorkspaceとして保存します。

- Workspace名を指定して保存します。
- ウィンドウの位置・サイズ・表示状態が保存されます。
- 保存データはJSONファイル形式です。

### Load（復元）

保存済みのWorkspace（`.json`）を読み込み、対象のウィンドウを起動・復元します。

- 保存時に存在したウィンドウを、ウィンドウ単位で判定します。
- 既に存在するウィンドウは、そのウィンドウを利用して配置を復元します。
- 存在しないウィンドウは、必要に応じてアプリケーションを起動して復元します。
- 保存対象に含まれないウィンドウは最小化されます。

### Delete（削除）

保存済みのWorkspace（`.json`）を削除します。

## 補足

- GUIからの操作中は、処理が完了するまで各操作ボタンが無効になります。
- WooorkFlip自身のウィンドウは、復元対象から除外されます。
- アプリケーションによっては、起動やウィンドウ復元に時間がかかる場合があります。
- Loadでは、保存対象に含まれないウィンドウが最小化される場合があります。実行前に作業中のファイルなどを保存してください。

---

## jsonファイルの例です。

例：test.json
```
{
  "schemaVersion": 1,
  "name": "test",
  "savedAt": "2026-11-07T20:58:40.1969940+09:00",
  "windows": [
    {
      "process": "explorer",
      "processPath": "C:\\Windows\\Explorer.EXE",
      "launchFile": null,
      "title": "ホーム - エクスプローラー",
      "class": "CabinetWClass",
      "state": "Normal",
      "normalX": 4014,
      "normalY": 167,
      "normalWidth": 974,
      "normalHeight": 523
    }
  ]
}

```

# コマンド操作（補足）

WooorkFlipは、PowerShell 7からコマンドで直接操作することもできます。

## 事前準備

PowerShell 7を起動し、スクリプトの保存先に移動します。

例
```powershell
cd D:\01_programming\02_WooorkFlip
```

以下では、ワークスペース名を `Test` とします。

## 1. ウィンドウ一覧を取得する（List）

### 実行コマンド

```powershell
.\WooorkFlip.ps1 -Action List
```

`Action` の初期値は `List` なので、次のコマンドでも同じ結果になります。

```powershell
.\WooorkFlip.ps1
```

### 確認項目

* ウィンドウ一覧が表示される
* Handle（ウィンドウハンドル）が表示される
* Process（プロセス名）が表示される
* Title（ウィンドウタイトル）が表示される
* ウィンドウの位置とサイズが表示される

### メモ

個別操作で使用するウィンドウのHandleを控えておきます。

例：`0x123456`

## 2. ワークスペースを保存する（Save）

### 実行コマンド

```powershell
.\WooorkFlip.ps1 -Action Save -Name Test
```

### 確認項目

* `Test` という名前で保存できる
* 保存されたウィンドウ数が正しい
* 保存ファイルが作成される
* ウィンドウの位置・サイズが保存される
* 最大化・最小化状態が保存される

### メモ

保存先は `WorkspaceDirectory` を指定しない場合、スクリプト側の既定値が使用されます。

## 3. 個別ウィンドウを操作する

手順1で取得したHandleを使用します。

以下の `0x123456` は、実際のウィンドウハンドルに置き換えてください。

### 3-1. 最小化（Minimize）

```powershell
.\WooorkFlip.ps1 -Action Minimize -Handle "0x123456"
```

確認項目：

* 指定したウィンドウが最小化される
* ほかのウィンドウには影響しない

### 3-2. 通常表示に戻す（Restore）

```powershell
.\WooorkFlip.ps1 -Action Restore -Handle "0x123456"
```

確認項目：

* 指定したウィンドウが通常表示に戻る

### 3-3. 最大化（Maximize）

```powershell
.\WooorkFlip.ps1 -Action Maximize -Handle "0x123456"
```

確認項目：

* 指定したウィンドウが最大化される

### 3-4. 前面に表示する（Focus）

```powershell
.\WooorkFlip.ps1 -Action Focus -Handle "0x123456"
```

確認項目：

* 指定したウィンドウが前面に表示される
* 対象ウィンドウがアクティブになる

## 4. ワークスペースを復元する（Load）

### 実行コマンド

```powershell
.\WooorkFlip.ps1 -Action Load -Name Test
```

### 確認項目

* 保存したアプリケーションが起動する
* ウィンドウ位置が復元される
* ウィンドウサイズが復元される
* 最大化状態が復元される
* 最小化状態が復元される
* 保存対象に含まれないウィンドウが最小化される
* 復元結果が一覧表示される
* Not found / Failed が発生しない

### 注意事項

Loadは、保存対象に含まれないウィンドウを最小化する場合があります。

実行前に作業中のファイルなどを保存してください。

## 5. その他のパラメーター

### 5-1. ProcessName

プロセス名を指定します。

```powershell
-ProcessName brave
```

確認項目：

* プロセス名を指定して対象を識別できる

### 5-2. Title

ウィンドウタイトルを指定します。

```powershell
-Title "WooorkFlip"
```

確認項目：

* ウィンドウタイトルを指定して対象を識別できる

### 5-3. ExcludeProcessId

指定したプロセスIDを除外します。

```powershell
-ExcludeProcessId 1234
```

確認項目：

* 指定したプロセスが処理対象から除外される

### 5-4. ExcludeHandle

指定したウィンドウハンドルを除外します。

```powershell
-ExcludeHandle 0x123456
```

確認項目：

* 指定したウィンドウが処理対象から除外される

### 5-5. WorkspaceDirectory

ワークスペースの保存先を指定します。

```powershell
-WorkspaceDirectory "D:\Workspaces"
```

確認項目：

* 指定したフォルダーにワークスペースが保存される
* 指定したフォルダーからワークスペースを読み込める