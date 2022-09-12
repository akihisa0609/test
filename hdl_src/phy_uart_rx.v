//-------------------------------------------------------------------
//! Module     : UART 受信ドライバ
//-------------------------------------------------------------------
// description :
//!  8bit + パリティ(あり/なし選択可)のUART受信ドライバ回路。<br>
//!  受信データバッファは持たないので、READY信号のタイミングで取得すること。<br>
//!  クロックイネーブル入力でサンプリングし、6サンプルで1bitとする。<br>
//!  そのため、クロックイネーブルの6倍周期のボーレートになる。<br>
//-------------------------------------------------------------------
//! **Timing Chart**
//! {
//!   head:{
//!     text:'Receive Control signals',
//!   },
//!   signal: [
//!     { name:'CLK',       wave:'p....|...........', period:1},
//!     { name:'UART_RX_EN',wave:'01...|...........' },
//!     { name:'RX_BUSY',   wave:'0...1|....0.....1' },
//!     { name:'DOUT_READY',wave:'0....|....10.....' },
//!     { name:'DOUT_BYTE', wave:'x....|....=...x..', data:["valid"]},
//!     { name:'UART_RX_IN',wave:'1.=..|=.=.....=..', data:["start bit","data","stop bit","start bit"]},
//!   ],
//!   edge: [
//!    'a~>b','c~>d'
//!   ],
//! }
//-------------------------------------------------------------------------------------------
`default_nettype none

module uart_driver_rx
  # (
    parameter P_UART_ACT   = 1'b0, //! 調歩同期のアサート論理 (1:正論理 / 0:負論理)
    parameter P_MSB_FIRST  = 1'b0, //! 1:MSB First / 0:LSB First
    parameter P_PARITY_EN  = 1'b0, //! 1:パリティ設定有効 / 0:パリティ無効
    parameter P_MSAMPLE_EN = 1'b0, //! 1:マルチサンプル有効(気持ちノイズ対策) / 0:1回サンプル
    parameter P_RST_ACT    = 1'b1  //! リセット論理 (1:正論理リセット / 0:負論理リセット)
  ) (
    input  wire RST_B,   //! 非同期リセット
    input  wire CLK,     //！クロック
    input  wire COM_CEN, //! サンプルクロックイネーブル(baudrateの6倍の周波数を入力)
    // (制御IF信号)
    input  wire       CFG_PTY_EN,  //! パリティ有無設定(1:パリティあり / 0:なし)
    input  wire       CFG_PTY_ODD, //! パリティ有無設定(1:奇数パリティ / 0:偶数パリティ)
    input  wire       UART_RX_EN,  //! 受信許可
    output wire       DOUT_READY,  //! 受信データあり 1clk"H"
    output wire [7:0] DOUT_BYTE,   //! 受信データ
    output wire       RX_BUSY,     //! 調歩同期中 (未使用時はopen)
    output wire       RX_ERR,      //! 通信エラー検出 1clk"H" (未使用時はopen)
    // (デバッグ信号:未使用時はopen)
    output wire RX_PTY_ERR,  //! エラー詳細:パリティエラー発生時 1clk"H"
    output wire RX_FRM_ERR,  //! エラー詳細:フレーミングエラー発生時 1clk"H"
    // (外部端子)
    input wire UART_RX_IN    //! UART入力
  );
  localparam C_NON_ASRT_VAL = ~P_UART_ACT; // 非アサート値
  localparam C_ASRT_VAL     = P_UART_ACT;  // アサート値

  // リセット正論理指定では、リセット入力を反転
  wire in_RST_B = P_RST_ACT ? ~RST_B : RST_B;

  //--+----+----+----+----+----+----+----+----+----+----+----+----+----+----+----
  // <<UART入力信号同期化の構造図>>                                    ______
  //                                       +------------------------->|      |
  //                                       |            +------------>|多数決|-->
  // ________   Z       ___   M      ___   |  a   ___ b |      ___ c  |      |
  // >_RX_IN_> ------->|FF |------->|FF |--+---->|FF |--+---->|FF |-->|______|
  //                   |___| ~~~    |___|        |___|        |___|
  //            reg_Rx_metas   reg_Rx_bit   reg_Rx_bitm(1)  reg_Rx_bitm(2)
  //
  // Path Z : 端子 - FF間。FPGA内部の配線にはDuty歪があるため、端子直近にFF配置し
  //          歪の影響が設計に進入しないようにした方がよい。配置配線毎のバラつきも減る。
  // Path M : メタステーブル発生パス。間には組み合わせ回路なしのFF対FF接続。
  //          "(Path遅延 + メタス安定時間) + Setup時間 < ClockCycle" を満たすこと。
  // Path a,b,c : 同期設計パス
  //--+----+----+----+----+----+----+----+----+----+----+----+----+----+----+----

  // 入力のメタステーブル対策FF
  // 受信信号入力を取込み (外部入力端子の入り口。メタスカット用FF)
  // [制約] reg_Rx_metas -> FF のパスにメタステーブルが発生する。最短配線。
  reg reg_Rx_metas;
  reg reg_Rx_bit;
  always @(posedge CLK or negedge in_RST_B) begin
    if (!in_RST_B) begin
      reg_Rx_metas <= C_NON_ASRT_VAL;
      reg_Rx_bit   <= C_NON_ASRT_VAL;
    end
    else begin
      reg_Rx_metas <= UART_RX_IN;   // 端子 - 入力信号受けFFパス [制約:できるだけ短く]
      reg_Rx_bit   <= reg_Rx_metas; // メタステーブル発生パス [制約:メタス収束時間分のパス制約]
    end  
  end


  wire in_RxSyncIn;

  generate
    if (P_MSAMPLE_EN) begin
    // [コンフィグレーション]: 複数回のサンプリングをして、多数決で入力ビットを決定する
      reg [2:1] reg_Rx_bitm;
      always @(posedge CLK or negedge in_RST_B) begin
        if (!in_RST_B) begin
          reg_Rx_bitm <= {8{C_NON_ASRT_VAL}};
        end
        else begin
          if (COM_CEN) begin
            reg_Rx_bitm[1] <= reg_Rx_bit;
            reg_Rx_bitm[2] <= reg_Rx_bitm[1];
          end
        end
      end

    // 入力の多数決回路
    // 真理値表 
    // (0,0,0)  => 0
    // (1,0,0)  => 0
    // (0,1,0)  => 0
    // (0,0,1)  => 0
    // (1,1,0)  => 1
    // (1,0,1)  => 1
    // (0,1,1)  => 1
    // (1,1,1)  => 1
    assign in_RxSyncIn = (reg_Rx_bitm[2] | reg_Rx_bitm[1]) &
                         (reg_Rx_bitm[1] | reg_Rx_bit    ) &
                         (reg_Rx_bit     | reg_Rx_bitm[2]);

    end
    else begin // (P_MSAMPLE_EN = 1'b0)
    // [コンフィグレーション]: 1回のサンプルで入力を決定する
      assign in_RxSyncIn  = reg_Rx_bit;

    end
  endgenerate


  //====== ステートマシン =============================
  // [2]  ==1'b1  調歩同期中条件
  // [1]  ==1'b1  reg_RxBitCntカウント条件
  // [2:1]==2'b01 エラー
  localparam [2:0] ST_RX_IDLE   = 3'b000,
                   ST_RX_RDY    = 3'b001,
                   ST_START_BIT = 3'b101,
                   ST_RX_DATA   = 3'b111,
                   ST_PARITY    = 3'b110,
                   ST_STOP_BIT  = 3'b100,
                   ST_ERR_PTY   = 3'b010,
                   ST_ERR_FRM   = 3'b011;
  reg [2:0] reg_RxState;
  reg [7:0] reg_RxByte;
  reg [2:0] reg_RxBitCnt;
  wire      in_SamplingUp;
  wire      in_ParityCalc;

  always @(posedge CLK or negedge in_RST_B) begin
    if (!in_RST_B) begin
      reg_RxState  <= ST_RX_IDLE;
      reg_RxByte   <= 8'b0;
    end
    else begin
      case (reg_RxState)
        ST_RX_IDLE : begin // STATE:アイドル 受信許可待ち
          if ((in_RxSyncIn == C_NON_ASRT_VAL) && (UART_RX_EN)) begin
            reg_RxState <= ST_RX_RDY;  //受信許可され、信号状態ディアサートで安定したら、受信待機へ
          end
        end

        ST_RX_RDY : begin  // STATE:スタートビット検出待ち
          if (!UART_RX_EN) begin
            reg_RxState <= ST_RX_IDLE;
          end
          else if ((in_RxSyncIn == C_ASRT_VAL) && (COM_CEN)) begin //スタートビットエッジ検出
            reg_RxState <= ST_START_BIT;
          end
        end

        ST_START_BIT: begin // STATE:スタートビット受信
          if (in_SamplingUp) begin
            if (in_RxSyncIn == C_ASRT_VAL) begin // スタートビットのセンター位置でサンプル確認
              reg_RxState <= ST_RX_DATA;
            end
            else begin // スタートビットエラー。ノイズとして捨て即RDYへ。信号安定の評価ができるようFRM_ERRに飛ばす
              reg_RxState <= ST_ERR_FRM;
            end
          end
        end

        ST_RX_DATA : begin // STATE:データビット受信
          if (in_SamplingUp) begin
            //受信データをシフトしながら格納する (LSB firstで格納する)
            reg_RxByte <= {in_RxSyncIn, reg_RxByte[7:1]};
            if (reg_RxBitCnt == 3'd0) begin
              if ((P_PARITY_EN) && (CFG_PTY_EN)) begin
                reg_RxState <= ST_PARITY; //パリティあり時は、パリティチェックへ
              end
              else begin
                reg_RxState <= ST_STOP_BIT;
              end
            end
          end
        end

        ST_PARITY : begin  // STATE:パリティビットの受信とチェック
          if (in_SamplingUp) begin
            if (in_RxSyncIn == in_ParityCalc) begin
              reg_RxState <= ST_STOP_BIT;
            end
            else begin
              reg_RxState <= ST_ERR_PTY; // パリティチェックエラー
            end
          end
        end 

        ST_STOP_BIT : begin  // STATE:ストップビットの受信とチェック
          if (in_SamplingUp) begin
            if (in_RxSyncIn == C_NON_ASRT_VAL) begin // stopビットのチェック
              reg_RxState <= ST_RX_RDY;
            end
            else begin
              reg_RxState <= ST_ERR_FRM; // フレーミングエラー
            end
          end
        end

        default : begin  // STATE:エラー処理 ST_ERR_PTY, ST_ERR_FRM, others
          // STOPビット不一致でフレーミングエラー時と、パリティ不一致時に来る。
          // (パリティ不一致時にしろ、非アサート状態になるまでIDLEで待たされる。)
          reg_RxState <= ST_RX_IDLE;  // IDLEに復帰
        end
      endcase
    end
  end

  // 受信データReady (StopBitが確認でき、ステート遷移する条件)
  reg  reg_RxDoutRdy;
  wire nxt_RxDoutRdy = ((reg_RxState == ST_STOP_BIT) && (in_SamplingUp)
                              && (in_RxSyncIn == C_NON_ASRT_VAL));
  always @(posedge CLK or negedge in_RST_B) begin
    if (!in_RST_B) begin
      reg_RxDoutRdy <= 1'b0;
    end
    else begin
      reg_RxDoutRdy <= nxt_RxDoutRdy;
    end
  end

  // 受信データビット数のカウント
  always @(posedge CLK or negedge in_RST_B) begin
    if (!in_RST_B) begin
      reg_RxBitCnt <= 3'd7;
    end
    else begin
      // カウントしないといけないステートは、ST_RX_DATAのみ
      // (最適化させるために、Don'tcareな条件をORして、reg_RxState[1]相当に)
      if ((reg_RxState == ST_RX_DATA) ||
          (reg_RxState == ST_PARITY) ||
          (reg_RxState == ST_ERR_PTY) ||
          (reg_RxState == ST_ERR_FRM)) begin
        if (in_SamplingUp) begin
          reg_RxBitCnt <= reg_RxBitCnt - 3'd1;
        end
      end
      else begin
        reg_RxBitCnt <= 3'd7;
      end
    end
  end

  // [コンフィグレーション]: パリティありの時の演算回路
  generate
    if (P_PARITY_EN) begin
      // RX_DATAで演算する (Don't careなステートをORする)
      wire in_calc_prty = ((reg_RxState == ST_RX_DATA)||(reg_RxState == ST_ERR_FRM));

      // ST_PARITYでholdする (Don't careなステートをORする)
      wire in_hold_prty = ((reg_RxState == ST_PARITY)||(reg_RxState == ST_ERR_PTY));

      reg reg_ParityCalc;
      always @(posedge CLK or negedge in_RST_B) begin
        if (!in_RST_B) begin
          reg_ParityCalc <= 1'b0;
        end
        else begin
          if (in_calc_prty) begin
            if (in_SamplingUp) begin
              reg_ParityCalc <= in_RxSyncIn ^ reg_ParityCalc; // パリティ計算
            end
          end
          else if (in_hold_prty) begin
            reg_ParityCalc <= reg_ParityCalc; // hold
          end
          else begin
            reg_ParityCalc <= CFG_PTY_ODD; // 他は初期化する
          end
        end
      end
      assign in_ParityCalc = reg_ParityCalc;

    end
    else begin
      assign in_ParityCalc = 1'b0;
    end
  endgenerate


  // 調歩同期中信号 (最適化でreg_RxState[2]相当になる)
  wire in_Uart_Busy = ((reg_RxState == ST_START_BIT) ||
                       (reg_RxState == ST_RX_DATA) ||
                       (reg_RxState == ST_PARITY) ||
                       (reg_RxState == ST_STOP_BIT));
  reg  [2:0] reg_SamplingCnt;
  always @(posedge CLK or negedge in_RST_B) begin
    if (!in_RST_B) begin
      reg_SamplingCnt <= 3'b010; // FPGA最適化時は同期リセットのみとする
    end
    else begin
      if (in_Uart_Busy) begin
        if (COM_CEN) begin
          if (reg_SamplingCnt == 3'd0) begin
            reg_SamplingCnt <= 3'b101;
          end
          else begin
            reg_SamplingCnt <= reg_SamplingCnt - 3'd1;
          end
        end
      end
      else begin
        reg_SamplingCnt <= 3'b010; // カウントしないステートでは2に相当する値で初期化
      end
    end
  end
  assign in_SamplingUp = COM_CEN && (reg_SamplingCnt == 3'd0);


  // 制御IF信号
  assign DOUT_READY = reg_RxDoutRdy;
  assign RX_BUSY    = in_Uart_Busy;
  assign RX_ERR     = ((reg_RxState == ST_ERR_PTY) || (reg_RxState == ST_ERR_FRM));

  generate
    if (P_MSB_FIRST) begin
      assign DOUT_BYTE = reg_RxByte;
    end
    else begin
      assign DOUT_BYTE = {reg_RxByte[0],reg_RxByte[1],reg_RxByte[2],reg_RxByte[3],
                          reg_RxByte[4],reg_RxByte[5],reg_RxByte[6],reg_RxByte[7]};
    end
  endgenerate

  // for Debug
  assign RX_PTY_ERR = (reg_RxState == ST_ERR_PTY);
  assign RX_FRM_ERR = (reg_RxState == ST_ERR_FRM);

endmodule

`default_nettype wire
