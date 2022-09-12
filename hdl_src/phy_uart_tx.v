//-------------------------------------------------------------------
//! Module : **UART 送信ドライバ**
//-------------------------------------------------------------------
// description :
//!  8bit + パリティ(あり/なし選択可)のUART送信ドライバ回路。<br>
//!  送信Readyの時に1byteライトすることで、1byte分送信される。<br>
//!  READYとなっていない時のライトは無効。最速でUART送信したい場合は、
//!  DIN_WRはアサートしたまま、READYで次のデータに切り替えるなどするとよい。<br>
//!  クロックイネーブル入力を6サンプルで1bitとする。<br>
//!  そのため、クロックイネーブルの6倍周期のボーレートになる。<br>
//-------------------------------------------------------------------
//! **Timing Chart**
//! {
//!   head:{
//!     text:'Transmit Control signals',
//!   },
//!   signal: [
//!     { name:'CLK',         wave:'p......|..|......', period:1},
//!     { name:'DIN_WR_READY',wave:'1.0....|..|..10..' },
//!     { name:'DIN_WR',      wave:'01x....|..|..1x..' },
//!     { name:'DIN_BYTE',    wave:'x=x....|..|..=x..' },
//!     { name:'UART_TX_OUT', wave:'1...=..|=.|=..=..', data:["start bit","data","stop bit","start bit"]},
//!     { name:'UART_DE_OUT', wave:'0..1...|..|......', },
//!   ],
//! }
//-------------------------------------------------------------------------------------------
`default_nettype none

module uart_driver_tx
  # (
    parameter P_UART_ACT  = 1'b0, //! 調歩同期のアサート論理 (1:正論理 / 0:負論理)
    parameter P_MSB_FIRST = 1'b0, //! 1:MSB First / 0:LSB First
    parameter P_PARITY_EN = 1'b0, //! 1:パリティ設定有効 / 0:パリティ無効
    parameter P_TXDE_EN   = 1'b1, //! 1:送信イネーブル制御有効 / 0:無効
    parameter P_RST_ACT   = 1'b0  //! リセット論理 (1:正論理リセット / 0:負論理リセット)
  ) (
    input  wire RST_B,   //! 非同期リセット
    input  wire CLK,     //！クロック
    input  wire COM_CEN, //! サンプルクロックイネーブル(baudrateの6倍の周波数を入力)
    // (制御IF信号)
    input  wire      CFG_PTY_EN,   //! パリティ有無設定(1:パリティあり / 0:なし)
    input  wire      CFG_PTY_ODD,  //! パリティ有無設定(1:奇数パリティ / 0:偶数パリティ)
    input  wire      DIN_WR,       //! 送信データライト
    input  wire[7:0] DIN_BYTE,     //! 送信データ1byte
    output wire      DIN_WR_READY, //! 送信データライト準備OK
    // (デバッグ信号:未使用時は初期値固定)
    input  wire TEST_PTY_ERR, //! (テスト)パリティエラー発生
    input  wire TEST_FRM_ERR, //! (テスト)フレーミングエラー発生
    // (外部端子)
    output wire UART_DE_OUT,  //! 送信イネーブル制御信号
    output wire UART_TX_OUT   //! UARTデータ出力
  );

  localparam C_NON_ASRT_VAL = ~P_UART_ACT; // 非アサート値
  localparam C_ASRT_VAL     = P_UART_ACT;  // アサート値

  // リセット正論理指定では、リセット入力を反転
  wire in_RST_B = P_RST_ACT ? ~RST_B : RST_B;


  wire [7:0] in_TxData;
  generate
    if (P_MSB_FIRST) begin
      assign in_TxData = DIN_BYTE;
    end
    else begin
      assign in_TxData = {DIN_BYTE[0],DIN_BYTE[1],DIN_BYTE[2],DIN_BYTE[3],
                          DIN_BYTE[4],DIN_BYTE[5],DIN_BYTE[6],DIN_BYTE[7]};
    end
  endgenerate

  //====== ステートマシン =============================
  // [2:1] != 2'b00 サンプリングカウント中
  // [1]   == 1'b1  reg_TxBitCntカウント条件
  localparam [2:0] ST_TX_IDLE   = 3'b000,
                   ST_TX_WAIT   = 3'b001,
                   ST_PRE_DE    = 3'b011,
                   ST_START_BIT = 3'b010,
                   ST_TX_DATA   = 3'b110,
                   ST_PARITY    = 3'b100,
                   ST_STOP_BIT  = 3'b101,
                   ST_DMY       = 3'b111;
  reg [2:0] reg_TxState;
  reg       reg_DinRdy;
  reg [7:0] reg_TxByte;
  reg [2:0] reg_TxBitCnt;
  wire      in_SamplingUp;
  wire      in_FrameStop;
  wire      in_Uart_DE;

  always @(posedge CLK or negedge in_RST_B) begin
    if (!in_RST_B) begin
      reg_TxState <= ST_TX_IDLE;
      reg_DinRdy  <= 1'b0;
      reg_TxByte  <= {8{1'b1}};
    end
    else begin
      case (reg_TxState)
        ST_TX_IDLE : begin // STATE:アイドル 送信データ待機状態
          if (DIN_WR) begin
            reg_TxByte <= in_TxData;
            reg_DinRdy <= 1'b0;
            if (COM_CEN) begin
              if (in_Uart_DE) begin
                reg_TxState <= ST_START_BIT;
              end
              else begin
                reg_TxState <= ST_PRE_DE;
              end
            end
            else begin
              //COM_CENのタイミングに合わせるために待ちステートへ
              reg_TxState <= ST_TX_WAIT;
            end
          end
          else begin
            reg_DinRdy <= 1'b1;
          end
        end

        ST_TX_WAIT : begin // STATE:クロックイネーブル同期待ち
          if (COM_CEN) begin
            if (in_Uart_DE) begin
              reg_TxState <= ST_START_BIT;
            end
            else begin
              reg_TxState <= ST_PRE_DE; // DE待ち
            end
          end
        end

        ST_PRE_DE : begin // STATE:データイネーブル安定待ち
          if (in_SamplingUp) begin
            reg_TxState <= ST_START_BIT;
          end
        end

        ST_START_BIT : begin // STATE:スタートビット送出
          if (in_SamplingUp) begin
            reg_TxState <= ST_TX_DATA;
          end
        end

        ST_TX_DATA : begin // STATE:データビット送信
          if ((in_SamplingUp) && (reg_TxBitCnt == 3'd0)) begin
            if ((P_PARITY_EN) && (CFG_PTY_EN)) begin
              reg_TxState <= ST_PARITY;
            end
            else begin
              reg_TxState <= ST_STOP_BIT;
            end
          end
        end 

        ST_PARITY : begin // STATE:パリティビットの送信
          if (in_SamplingUp) begin
            reg_TxState <= ST_STOP_BIT;
          end
        end

        default : begin // STATE:ストップビット送信, others
          // 連続送信時に、ストップビットが綺麗に1byte分になるようにする。
          if (in_FrameStop) begin
            reg_TxState <= ST_TX_IDLE;
            reg_DinRdy  <= 1'b1;
          end
        end
      endcase
    end
  end


  // 送信データビット数のカウント
  always @(posedge CLK or negedge in_RST_B) begin
    if (!in_RST_B) begin
      reg_TxBitCnt <= 3'd7;
    end
    else begin
      // カウントしないといけないステートは、TX_DATAのみ
      // (最適化させるために、Don'tcareな条件をORする)
      if ((reg_TxState == ST_TX_DATA) ||
          (reg_TxState == ST_PARITY) ||
          (reg_TxState == ST_STOP_BIT) ||
          (reg_TxState == ST_DMY)) begin
        if (in_SamplingUp) begin
          reg_TxBitCnt <= reg_TxBitCnt - 3'd1;
        end
      end
      else begin
        reg_TxBitCnt <= 3'd7;
      end
    end
  end


  // [コンフィグレーション]: パリティありの時の演算回路
  wire nxt_TxBit;
  wire in_ParityCalc;
  generate
    if (P_PARITY_EN) begin
      reg reg_ParityCalc;

      always @(posedge CLK or negedge in_RST_B) begin
        if (!in_RST_B) begin
          reg_ParityCalc <= 1'b0;
        end
        else begin
          case (reg_TxState)
            ST_START_BIT : begin
              reg_ParityCalc <= CFG_PTY_ODD ^ TEST_PTY_ERR; //エラー機能有効なら、初期値を変える
            end
            
            ST_TX_DATA : begin // RX_DATAで演算する
              if (in_SamplingUp) begin
                reg_ParityCalc <= reg_ParityCalc ^ nxt_TxBit; // パリティ計算
              end
              else begin
                reg_ParityCalc <= reg_ParityCalc; // hold
              end
            end
            ST_PARITY : begin // ST_PARITYでholdする
              reg_ParityCalc <= reg_ParityCalc; // hold
            end
            default : begin  // 他は初期化する
              reg_ParityCalc <= CFG_PTY_ODD;
            end
          endcase
        end
      end
      assign in_ParityCalc = reg_ParityCalc;

    end
    else begin  // (!P_PARITY_EN)
      assign in_ParityCalc = 1'b0;
    end
  endgenerate

  reg [2:0] reg_SamplingCnt;
  wire in_SampleCnt_zero = (reg_SamplingCnt == 3'd0);
  always @(posedge CLK or negedge in_RST_B) begin
    if (!in_RST_B) begin
      reg_SamplingCnt <= 3'd5;
    end
    else begin
      if ((reg_TxState == ST_TX_IDLE) || (reg_TxState == ST_TX_WAIT)) begin
        // IDLEと、TX_WAITでクリア。他は常にカウント
        reg_SamplingCnt <= 3'd5;
      end
      else if (COM_CEN) begin
        if (in_SampleCnt_zero) begin
          reg_SamplingCnt <= 3'd5;
        end
        else begin
          reg_SamplingCnt <= reg_SamplingCnt - 3'd1;            
        end
      end
    end
  end
  assign in_SamplingUp = COM_CEN && in_SampleCnt_zero;
  assign in_FrameStop  = COM_CEN && (reg_SamplingCnt == 3'd1);


  // DE信号が有効なら制御する
  generate
    if (P_TXDE_EN) begin
      reg [1:0] reg_Uart_DE_Cnt;
      reg       reg_Uart_DE;
      always @(posedge CLK or negedge in_RST_B) begin
        if (!in_RST_B) begin
          reg_Uart_DE     <= 1'b0;
          reg_Uart_DE_Cnt <= 2'd0;
        end
        else begin
          case (reg_TxState)
            ST_TX_IDLE : begin
              if (reg_Uart_DE) begin
                if ((reg_Uart_DE_Cnt == 2'd0) && (!DIN_WR)) begin
                  reg_Uart_DE  <= 1'b0; // 遅延カウント完了したらディアサート
                end
              end
              if (COM_CEN) begin
                reg_Uart_DE_Cnt <= reg_Uart_DE_Cnt - 1;
              end
            end
            
            ST_TX_WAIT : begin
              reg_Uart_DE <= reg_Uart_DE;// hold
              reg_Uart_DE_Cnt <= 2'd3;
            end
          
            default : begin  // others
              reg_Uart_DE     <= 1'b1;
              reg_Uart_DE_Cnt <= 2'd3;
            end
          endcase
        end
      end
      assign in_Uart_DE = reg_Uart_DE;

    end
    else begin  // (!P_TXDE_EN)
      assign in_Uart_DE = 1'b1; // 常に有効で出力

    end
  endgenerate

  // TX_OUTをステートに応じてFFで出力する
  assign nxt_TxBit = reg_TxByte[reg_TxBitCnt]; // (ビットシフトよりMUXの方がLUT効率がよい)
  reg  nxt_Uart_TX;
  always @(*) begin
    case (reg_TxState)
      ST_START_BIT : nxt_Uart_TX <= C_ASRT_VAL;
      ST_TX_DATA   : nxt_Uart_TX <= nxt_TxBit;
      ST_PARITY    : nxt_Uart_TX <= in_ParityCalc;
      ST_STOP_BIT  : nxt_Uart_TX <= C_NON_ASRT_VAL ^ TEST_FRM_ERR;
      default      : nxt_Uart_TX <= C_NON_ASRT_VAL; // others
    endcase
  end

  // UART出力FF
  reg  reg_Uart_TX;
  always @(posedge CLK or negedge in_RST_B) begin
    if (!in_RST_B) begin
      reg_Uart_TX  <= C_NON_ASRT_VAL;
    end
    else begin
      reg_Uart_TX  <= nxt_Uart_TX;
    end
  end


  // 出力
  assign DIN_WR_READY = reg_DinRdy;
  assign UART_DE_OUT  = in_Uart_DE;
  assign UART_TX_OUT  = reg_Uart_TX;

endmodule

`default_nettype wire
