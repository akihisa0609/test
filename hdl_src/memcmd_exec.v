//--------------------------------------------------------------------------------------------------
// **Module: メモリアクセスコマンド実行制御**
//--------------------------------------------------------------------------------------------------
// Comment :
//  以下のフレームフォーマットを読み取り、内部バスアクセスを実行する
//
// ・フレーム (コマンド)
//    bit 15 - 12   | bit11     | bit 10- 0
//    --------------+-----------+-------------------------------
// +0 シーケンスNo  | 強制実行※| 全体ワード長-1
//   ※シーケンスNoが一致していれば実行しないが、初回など強制実行したいときは'1'とする。
//     常に'1'とすると、シーケンスNoチェックは行われず、常に実行される。
// +1 コマンド1
//    コマンド1のデータ ・・・
// +* コマンド2
//    コマンド2のデータ ・・・
// +N 終端コマンド 0xFFFF (終端コマンドとして、最後に必ず付けること)
//
// ・フレーム (正常レスポンス)
//    bit 15 - 12   | bit11     | bit 10- 0
//    --------------+-----------+-------------------------------
// +0 シーケンスNo  | エラー=0  | 全体ワード長-1 (フィールドの幅はG_CMD_A_WIDTHで設定)
// +1 コマンド1のリードデータ ・・・ (ライトのレスポンスはなし)
// +* コマンド2のリードデータ ・・・ (ライトのレスポンスはなし)
// +N 終端データ 0xFFFF (レスポンスの最後には必ず1ワード付く
//
// ・フレーム (異常レスポンス)
//    bit 15 - 12   | bit11     | bit 10- 0
//    --------------+-----------+-------------------------------
// +0 シーケンスNo  | エラー=1  | 全体ワード長=0
// +1 終端データ 0xFFFF
//    ※コマンドが異常でコマンド、レスポンス長を超える時、エラーがONする。
//      通信フレームチェックは事前に実施済の前提なので、基本的にバグ以外でエラーはONしない。
//
//
//  [個別コマンド]
// ・連続リードコマンド (2ワード)
//    bit 15 - 13   | bit 12-9  | bit 8-0 (フィールドの幅はG_EXE_W_LENで設定)
//    --------------+-----------+----------------------------
// +0 Code = "101"  | 0固定     | 読みワード長-1 
// +1 アドレス(Word単位アドレス)
//
// ・連続ライトコマンド (2+Nワード)
//    bit 15 - 13   | bit 12-9  | bit 8-0 (フィールドの幅はG_EXE_W_LENで設定)
//    --------------+-----------+----------------------------
// +0 Code = "100"  | 0固定     | 書きワード長-1
// +1 アドレス(Word単位アドレス)
// +2 ライトデータ (Nワード続く)
//
// ・単発リードコマンド (1ワード)
//    bit 15 - 14   | bit 13 - 0
//    --------------+-----------+----------------------------
// +0 Code = "01"   | アドレス(Word単位アドレス)
//
// ・単発ライトコマンド (2ワード)
//    bit 15 - 12   | bit 13 - 0
//    --------------+-----------+----------------------------
// +0 Code = "00"   | アドレス(Word単位アドレス)
// +1 ライトデータ (1ワードのみ)
//
// ・NOPコマンド (1ワード)
//    bit 15 - 12   | bit 11-0
//    --------------+----------------------------------------
// +0 Code = "1110" | Don't care 
//
// ・終端コマンド (1ワード)
//    bit 15 - 12   | bit 11-0
//    --------------+----------------------------------------
// +0 Code = "1111" | Don't care 

//--------------------------------------------------------------------------------------------------
//--------------------------------------------------------------------------------------------------
// Comment :
//  シーケンスNoをチェックする場合は、前回シーケンスNoは呼び出し側で保持すべき。
//  ※このコマンド解釈実行エンジンは、どのフレームを処理させられているか知らないため、
//    複数フレームなどの複数のシーケンスNoを管理する場合は、本モジュール内に保持するのは変。
//  したがって、シーケンスNoのチェックを行う場合は、以下のように呼び出し側で保持すること。
//
//  process (RST_B, CLK)
//  begin
//    if (RST_B = '0') then
//      SEQ_NO_REF <= "10000";
//    elsif (CLK'event and CLK = '1') then
//      if (SEQ_NO_WR = '1') then
//        SEQ_NO_REF <= SEQ_NO_WDAT;
//      end if;
//    end if;
//  end process;
//--------------------------------------------------------------------------------------------------

//[Time chart]--------------------------------------------------------------------------------
// コマンドメモリに準備完了した状態から、EXEC_REQをする。
// G_EXEC_ADR_EN='1'時は、RAM開始アドレスを開始時に指定できる。
//             _   _   _   _   _   _   _   _   _   _   _   _   _   _   _   _   _   _   _   _   _   _   _
//  CLK     __| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_| |_|
//             ___ ___                                                
// EXEC_REQ __|   |___|________________________________________________________________________________
//                 _______________________________________________________________________________
// EXEC_BUSY _____|                                                                            ___|____
// EXEC_FIN  _________________________________________________________________________________|___|____
//                                                                                         ___
// EXEC_ERR  _________|///_______________________________________________________________/////|   |____
//
//          __________________ _______ ___ _______ _______ _______ ___ _______ ___ _______ _______
// BUS_ADDR __________________X_____A1X_A2X_A3____X_A4____X_______X_A1X_A2____X_A3X_______X_______
//                             _______ ___ _______ _______
// BUS_RD_REQ  _______________|       |   |       |       |_______________________________________
//                                                                 ___ _______ ___
// BUS_WR_REQ   __________________________________________________|___|_______|___|________________
// BUS_WR_DAT   __________________________________________________X_D1X_D2____X_D3X________________
//              ______________     ___ ___     ___     ___ ___ _______     ___ ___     ___ ________
// BUS_READY               ///|___|   |   |___|   |___|   |   |       |___|   |   |___|   |
//              ______________________ ___ ___ ___ ___ ___ ___ ____
// BUS_RD_DAT   ______________________X_A1X___X_A2X___X_A3X_A4X____
//-------------------------------------------------------------------------------------------
`default_nettype none

module memcmd_exec
  # (
    parameter [3:0] P_CMD_A_WIDTH = 4'd9,  //! 通信フレームメモリアドレス幅(9=512ワードRAM,8=256ワードRAM)
    parameter [3:0] P_BUS_A_WIDTH = 5'd16, //! 内部バスアドレス幅(Byte単位, 16=64KByte,12=4KByte)
    parameter [3:0] P_EXE_W_LEN   = 4'd9,  //! 実行コマンド読み書きワード長幅(9=Max512ワード,8=Max256ワード)
    parameter [3:0] P_SEQ_CHK_EN  = 1'b0,  //! シーケンスNoのチェック(1:有効 / 0:無効)
    parameter [3:0] P_EXEC_ADR_EN = 1'b0,  //! コマンド/レスポンスRAM開始指定を有効にする
    parameter [3:0] P_FRAMELEN_EN = 1'b0,  //! フレーム長チェック(1:有効 / 0:無効)
    parameter       P_RST_ACT     = 1'b0   //! リセット論理
  ) (
    input  wire RST_B,
    input  wire CLK,
    // メモリコマンド実行制御 IF
    input  wire        EXEC_REQ,     //! 実行開始要求
    output wire        EXEC_BUSY,    //! コマンド実行Busy
    output wire        EXEC_FIN,     //! コマンド実行完了(1clk'H') 
    output wire        EXEC_ERR,     //! コマンド実行エラー
    // コマンドFIFO
    output wire [1:0]  EXEC_CMD_NXT, //! コマンドFIFO次データ要求
    input  wire [31:0] EXEC_CMD_DAT, //! コマンドFIFOデータ
    output wire [1:0]  EXEC_RSP_WR,  //! レスポンスFIFOライト要求
    output wire [31:0] EXEC_RSP_DAT, //! コマンドFIFOデータ
    // チェック用シーケンスNo保持用 IF(G_SEQ_CHK_EN='1'時に使用し、外部に保持FFを作る)
    input  wire [3:0]  SEQ_NO_REF,  //! シーケンスNo参照値
    output wire        SEQ_NO_WR,   //! シーケンスNoライト(1clk"H")
    output wire [3:0]  SEQ_NO_WDAT, //! シーケンスNoライト値
    // 内部バスアクセス IF
    output wire [16:2] MLBUS_RADR,
    output wire        MLBUS_RREQ,
    input  wire        MLBUS_RRDY,
    input  wire        MLBUS_RVLD,
    input  wire [31:0] MLBUS_RDAT,
    output wire [16:2] MLBUS_WADR,
    output wire        MLBUS_WREQ,
    output wire [1:0]  MLBUS_WSTB,
    input  wire        MLBUS_WRDY
  );

  // リセット正論理指定では、リセット入力を反転
  wire in_RST_B = P_RST_ACT ? ~RST_B : RST_B;

  // コマンドオペコードのデコード
  wire in_opcode_2w;
  wire in_opcode_rw; 
  wire in_opcode_fin;
  wire in_opcode_nop;
  wire in_opcode_err;

  always @(*) begin
    if (MCMD_RD_DAT[15] == 1'b0) begin
      // 1word Read or Write
      in_opcode_fin <= 1'b0;
      in_opcode_nop <= 1'b0;
      in_opcode_2w  <= 1'b0;
      in_opcode_rw <= MCMD_RD_DAT(14);
      in_opcode_err <= 1'b0;
    end
    else if (MCMD_RD_DAT[14] == 1'b1) begin
      if (MCMD_RD_DAT[13:12] == 2'b11) begin
        in_opcode_fin <= 1'b1; //ターミネーションコマンド
        in_opcode_nop <= 1'b0;
        in_opcode_err <= 1'b0;
      end
      if (MCMD_RD_DAT[13:12] == 2'b10) begin
        in_opcode_fin <= 1'b0;
        in_opcode_nop <= 1'b1; //NOPコマンド
        in_opcode_err <= 1'b0;
      end
      else begin
        in_opcode_fin <= 1'b0;
        in_opcode_nop <= 1'b0;
        in_opcode_err <= 1'b1; //未知のコマンドエラー
      end
      in_opcode_2w <= 1'b0;
      in_opcode_rw <= 1'b0;
    end
    else begin
      // 2word Read or Write
      in_opcode_fin <= 1'b0;
      in_opcode_nop <= 1'b0;
      in_opcode_2w  <= 1'b1;
      in_opcode_rw <= MCMD_RD_DAT(13);
      in_opcode_err <= 1'b0;
    end
  end


  reg  reg_cmd_adr_err;
  wire in_cmd_adr_err;
  wire in_rsp_adr_err;
  wire in_rsp_wr_err;
  wire [9:0] in_cmd_sta_addr = {1'b0, EXEC_CMD_ADR};
  wire [9:0] in_rsp_sta_addr = {1'b0, EXEC_RSP_ADR};
  wire in_any_err <= in_rsp_adr_err | in_cmd_adr_err | in_opcode_err;

  // メイン実行ステートマシン
  localparam [2:0] ST_IDLE      = 3'b000,
                   ST_RD_HEAD   = 3'b001,
                   ST_FETCH_CMD = 3'b011,
                   ST_WR_RDY    = 3'b010,
                   ST_EXE_WR    = 3'b111;
                   ST_EXE_RD    = 3'b110,
                   ST_RD_WAIT   = 3'b100,
                   ST_WR_RSP    = 3'b101,
  reg  [2:0] reg_state;
  reg        reg_rw_cmd;
  reg  [3:0] reg_seq_no;
  reg  [9:0] reg_cmd_addr;
  reg [1:0]  reg_cmd_nxt;
  // (コマンドメモリから実行コマンドを読み出し、リード・ライトを実行制御する)
  always @(posedge CLK or negedge in_RST_B) begin
    if (!in_RST_B) begin
      reg_state    <= ST_IDLE;
      reg_cmd_nxt  <= 2'b00;
      reg_rw_cmd   <= 1'b0;
      reg_seq_no   <= 4'd0;
      reg_cmd_addr <= 10'd0;
    end
    else begin
      case (reg_state)
        ST_IDLE : begin
          if (EXEC_REQ) begin
            reg_state    <= ST_RD_HEAD;
            reg_cmd_addr <= in_cmd_sta_addr;
            reg_cmd_nxt  <= 2'b11;
          end
          else begin
            reg_cmd_nxt  <= 2'b00;
          end
        end

        ST_RD_HEAD begin //ヘッダ読み込み(シーケンスNoのチェック)
          reg_seq_no <= EXEC_CMD_DAT[15:12]; //通信で返す用に保持
          if ((EXEC_CMD_DAT[15:12] == SEQ_NO_REF) && (!EXEC_CMD_DAT[11])) begin
            //前回実行したシーケンスNoなので、実行しない。前回のレスポンスをそのまま返す。
            reg_state <= ST_FIN;
            reg_cmd_nxt  <= 2'b01;
          end
          else begin
            // コマンド内容の解釈開始
            reg_state <= ST_FETCH_CMD;
            reg_cmd_nxt  <= 2'b01;
          end
        end

        ST_FETCH_CMD : begin// コマンドのフェッチ
          if (reg_sub_cnt == 1'b0) begin
            reg_rw_cmd <= in_opcode_rw;
            if (in_opcode_fin || in_any_err) begin
              // 実行終了コマンド or コマンド、レスポンスオーバーランエラー
              reg_state <= ST_WR_RSP;
            end
            else if (in_opcode_2w) begin
              // 2wordオペランド (連続アクセス)
              reg_cmd_addr <= reg_cmd_addr + 10'd1;
            end
            else begin
              // 1wordオペランド (単発アクセス)
              if (in_opcode_nop) begin
                reg_state <= ST_FETCH_CMD;  //何もしない
              end
              else if (in_opcode_rw) begin
                reg_state <= ST_EXE_RD;  //リード
                // リードの時はコマンドアドレスは更新しない
              end
              else begin
                reg_state <= ST_WR_RDY;  //ライト
                reg_cmd_addr <= reg_cmd_addr + 10'd1;
              end
            end
          end
          else begin
            if (reg_rw_cmd) begin
              reg_state <= ST_EXE_RD; //リード
              // リードの時はコマンドアドレスは更新しない
            end
            else begin
              reg_state <= ST_WR_RDY;  //ライト
              reg_cmd_addr <= reg_cmd_addr + 10'd1;
            end
          end
        end

        ST_EXE_WR : begin // ライトコマンドの実行(必要なワード数を繰り返す)
          if (MLBUS_WRDY) begin
            reg_cmd_addr <= reg_cmd_addr + 10'd1;
            reg_sub_cnt <= ~[reg_sub_cnt];
          end

          if ((MLBUS_WRDY) && (reg_bus_wr != 2'b00)) begin
            // 書き込み要求が通ったら、アドレスを更新
            reg_mem_adr[0]    <= 1'b0;
            reg_mem_adr[15:1] <= reg_mem_adr[15:1] + 15'd1;
          end
          
          if (MLBUS_WRDY) begin
            if (reg_sub_cnt) begin
              reg_state <= ST_FETCH_CMD;
            end
            if (reg_mem_adr[0]) begin // 奇数ワードアドレスの時、データライト


            if (in_bus_ready) begin
            reg_cmd_addr <= reg_cmd_addr + 10'd1;
            if (in_data_last) begin
              reg_state <= ST_FETCH_CMD;
            end
          end
        end

        ST_EXE_RD : begin // リード要求実行
          if (MLBUS_RRDY) begin
            reg_state <= ST_RD_WAIT;
          end
        end

        ST_RD_WAIT : begin // リード結果読み出し待ち
          if (MLBUS_RVALD) begin
            reg_mem_adr[0]    <= 1'b0;
            reg_mem_adr[15:1] <= reg_mem_adr[15:1] + 15'd1;
            if (reg_mem_adr[0]) begin
              // 奇数ワードアドレスの時は、残りデータが1なら終了
              reg_word_num <= reg_word_num - 9'd1;
              if (reg_word_num == 0) begin
                reg_state <= ST_FETCH_CMD;
              end
              else begin
                reg_state <= ST_EXE_RD;
              end
            end
            else begin
              // 偶数ワードアドレスの時は、残りデータが2以下なら終了
              reg_word_num <= reg_word_num - 9'd2;
              if (reg_word_num <= 1) begin
                reg_state <= ST_FETCH_CMD;
              end
              else begin
                reg_state <= ST_EXE_RD;
              end
            end
          end
        end

        ST_WR_RSP : begin // レスポンスヘッダの書き込み
          reg_sub_cnt <= ~reg_sub_cnt;
          if (reg_sub_cnt) begin
            reg_state <= ST_IDLE;
          end
        end

        ST_FIN : begin // 終了コマンド0xFFFFの書き込み
          reg_state <= ST_IDLE;
        end

        default : begin // never come hear
          reg_state <= ST_IDLE;
        end

      endcase
    end
  end


  // 内部バスライト制御
  reg [31:0] reg_bus_wdat;
  reg [1:0]  reg_bus_wr;
  always @(posedge CLK or negedge in_RST_B) begin
    if (!in_RST_B) begin
      reg_rsp_addr <= 10'd0;
      reg_bus_rdat <= 32'h0;
      reg_rsp_wr   <= 2'b00;
    end
    else begin
      if (reg_state == ST_EXE_WR) begin
        if (MLBUS_WRDY) begin
          if (reg_sub_cnt == 1'b0) begin
            if (reg_mem_adr[0]) begin // 奇数ワードアドレス
              reg_bus_wdat[31:16] <= MCMD_RD_DAT;
              reg_bus_wr  <= 2'b10;
            end
            else begin  // 偶数ワードアドレス
              reg_bus_wdat[15:0] <= MCMD_RD_DAT;
              if (reg_word_num == 0) begin
                reg_bus_wr  <= 2'b01;
              end
              else begin
                reg_bus_wr  <= 2'b00; //まだかかない
              end
            end
          end
          else begin
            //32bitライトの時、ここ
            reg_bus_wdat[31:16] <= MCMD_RD_DAT;
            reg_bus_wr  <= 2'b11;
          end
        end
      end
      else begin
        if (MLBUS_WRDY) begin
          reg_bus_wr  <= 2'b00;
        end
      end
    end
  end

  assign MLBUS_WADR = reg_mem_adr[15:1];
  assign MLBUS_WREQ = (reg_bus_wr != 2'b00);
  assign MLBUS_WSTB = reg_bus_wr;
  assign MLBUS_RADR = reg_mem_adr[15:1];
  assign MLBUS_RREQ = (reg_state == ST_EXE_RD);


  // 内部バスリードデータのレスポンスバッファへのライト制御
  reg [9:0]  reg_rsp_addr;
  reg [31:0] reg_bus_rdat;
  reg [1:0]  reg_rsp_wr;
  always @(posedge CLK or negedge in_RST_B) begin
    if (!in_RST_B) begin
      reg_rsp_addr <= 10'd0;
      reg_bus_rdat <= 32'h0;
      reg_rsp_wr   <= 2'b00;
    end
    else begin
      if (reg_state == ST_IDLE) begin
        if (EXEC_REQ) begin
          // 指定開始アドレスからレスポンスを格納。リードデータは+1オフセットから書く
          reg_rsp_addr <= in_rsp_sta_addr + 10'd1;
        end
      end
      else if (reg_state == ST_WR_RSP) begin
        if (reg_sub_cnt) begin
          reg_rsp_addr <= 10'd0;
        end
      end
      else begin
        if (reg_rsp_wr != 2'b00) begin
          reg_rsp_addr <= reg_rsp_addr + 10'd1;
        end
      end
        
      if (reg_state == ST_RD_WAIT) begin
        if (MLBUS_RVLD) begin
          if (reg_mem_adr[0]) begin
            //奇数ワードからの読み出しは、上位16bitだけレスポンスに書く
            reg_bus_rdat[31:16] <= MLBUS_RDAT[31:16];
            reg_rsp_wr         <= 2'b10;
          end
          else if (reg_word_num == 0) begin
            //偶数ワードだが、残り読み数が1ワード分 => 下位16bitだけ
            reg_bus_rdat[15:0] <= MLBUS_RDAT[15:0];
            reg_rsp_wr         <= 2'b01;
          end
          else begin
            //偶数ワードで、残り読み数が2ワード以上 => 32bitすべて
            reg_bus_rdat[31:0] <= MLBUS_RDAT[31:0];
            reg_rsp_wr         <= 2'b11;
          end
        end
        else begin
          reg_rsp_wr <= 2'b00;
        end
      end
      else if (reg_state == ST_WR_RSP) begin
        if (reg_sub_cnt == 1'b0) begin
          // 終端とレスポンスヘッダを書き込むため、32bit分のレスポンスライトをセット
          reg_bus_rdat[15:0]  <= 16'hffff;
          reg_bus_rdat[31:16] <= {reg_seq_no, reg_cmd_err, 2'b0, (reg_rsp_addr[8:0]-9'd1)};
          reg_rsp_wr <= 2'b11;
        end
        else begin
          reg_rsp_wr <= 2'b10;          
        end
      end
      else begin
        if (reg_rsp_wr == 2'b11) begin
          reg_rsp_wr <= 2'b10;
        end
        else begin
          reg_rsp_wr <= 2'b00;
        end
      end
    end
  end

  assign MRSP_CS     = (reg_state != ST_IDLE);
  assign MRSP_WR     = (reg_rsp_wr != 2'b00);
  assign MRSP_ADDR   = reg_rsp_addr[8:0];
  assign MRSP_WR_DAT = (reg_rsp_wr[0]) ? reg_bus_rdat[15:0] : reg_bus_rdat[31:16];


  // レスポンスRAMへの書き戻し要求、アドレス制御
  reg       reg_rsp_wr;
  reg [9:0] reg_rsp_addr;
  wire      nxt_rsp_addr_inc = reg_rsp_addr + 10'd1;
  always @(posedge CLK or negedge in_RST_B) begin
    if (!in_RST_B) begin
      reg_rsp_wr   <= 1'b0;
      reg_rsp_addr <= 10'd0;
    end
    else begin
      if (reg_state == ST_WR_RSP) begin
        reg_rsp_wr <= 1'b1;
      end
      else if (reg_state == ST_EXE_RD) begin
        if (in_bus_ready) begin
          reg_rsp_wr <= 1'b1;
        end
      end
      else if (reg_state == ST_EXE_RDWAIT) begin
        if (in_bus_ready) begin
          reg_rsp_wr <= 1'b0;
        end
      end
      else begin
        reg_rsp_wr <= 1'b0;
      end

      if (reg_state == ST_IDLE) begin
        if (EXEC_REQ) begin
          reg_rsp_addr <= in_rsp_sta_addr;
        end
      end
      else if (reg_state == ST_FETCH_CMD) begin
        if (in_opcode_err) begin
          reg_rsp_addr <= 10'd0;
        end
      end
      else if (reg_state == ST_EXE_RD) begin
        if (in_bus_ready) begin
          reg_rsp_addr <= nxt_rsp_addr_inc;
        end
      end
      else if ((reg_state == ST_WR_RSP) || (reg_state == ST_FIN)) begin
        reg_rsp_addr <= nxt_rsp_addr_inc;
      end
      else begin
        reg_rsp_addr <= reg_rsp_addr; // hold
      end
    end
  end

  // コマンドアドレスエラーは、FFで叩いたものをチェックする
  assign in_cmd_adr_err <= reg_cmd_adr_err;
  // レスポンスアドレスエラーは、終端データ書き込みまで含めてチェックするので、次のアドレスでチェック
  assign in_rsp_adr_err = nxt_rsp_addr_inc[9];
  // レスポンスライト時のエラーは、まさに書き込むアドレスがオーバーフローしたらエラーにする
  assign in_rsp_wr_err  = reg_rsp_addr[9];


  // ライトデータの保持 (READY=OFF時に、ライトデータを保持する)
  process (in_RST_B, CLK)
  begin
    if (in_RST_B = '0') then
      reg_bus_wdata  <= (others => '0');
      reg_bus_rdy_en <= '1';
    elsif (CLK'event and CLK = '1') then
      if (reg_state = ST_EXE_WR) then
        if (reg_bus_rdy_en = '1') then
          reg_bus_wdata <= MCMD_RD_DAT;
        end if;
      end if;
      if (reg_state = ST_EXE_WR) then
        reg_bus_rdy_en <= BUS_READY;
      else
        reg_bus_rdy_en <= '1';
      end if;
    end if;
  end process;
  mux_bus_wdata <= MCMD_RD_DAT when (reg_bus_rdy_en = '1') else reg_bus_wdata;



  -- コマンド実行条件等の生成
  process (in_RST_B, CLK)
  begin
    if (in_RST_B = '0') then
      reg_addr_cmd <= '1';  -- コマンド読み出時に、連続アクセスを制御する(2クロックかけて読み出す)
      reg_data_len <= (others => '0');
      reg_bus_addr <= (others => '0');
    elsif (CLK'event and CLK = '1') then
      case reg_state is
      when ST_IDLE =>
        reg_addr_cmd <= '1';
        reg_bus_addr <= (others => '0');
        reg_data_len <= (others => '0');

      when ST_FETCH_CMD =>
        if (reg_addr_cmd = '0') then
          if (in_opcode_nop = '0') then
            reg_addr_cmd <= '1';
          end if;
          reg_bus_addr <= in_short_addr; --単発アクセスのアドレス
          if (in_opcode_2w = '1')  then
            reg_data_len <= MCMD_RD_DAT(reg_data_len'left downto 0); --連続アクセス
          else
            reg_data_len <= (others => '0'); --単発アクセス
          end if;
        else
          reg_bus_addr <= MCMD_RD_DAT(G_BUS_A_WIDTH-2 downto 0); --連続アクセスのアドレス
          reg_addr_cmd <= '0';
        end if;

      when ST_EXE_WR | ST_EXE_RD =>
        reg_addr_cmd <= '0';
        if (in_bus_ready = '1') then
          reg_bus_addr <= reg_bus_addr + 1;
          reg_data_len <= reg_data_len - 1;
        end if;

      when others =>
        reg_addr_cmd <= '0';
        reg_bus_addr <= (others => '0');
        reg_data_len <= (others => '0');
      end case;
    end if;
  end process;

  in_data_last  <= '1' when (0 = reg_data_len) else '0';
  in_bus_ready  <= BUS_READY;

  GEN_SHORT_ADDR_15 : if (G_BUS_A_WIDTH >= 15) generate
    in_short_addr(in_short_addr'left downto 13) <= (others => '0');
    in_short_addr(12 downto 0)                  <= MCMD_RD_DAT(12 downto 0);
  end generate;
  GEN_SHORT_ADDR_14 : if (G_BUS_A_WIDTH <= 14) generate
    in_short_addr <= MCMD_RD_DAT(in_short_addr'left downto 0);
  end generate;


  -- ライトデータの保持 (READY=OFF時に、ライトデータを保持する)
  process (in_RST_B, CLK)
  begin
    if (in_RST_B = '0') then
      reg_bus_wdata  <= (others => '0');
      reg_bus_rdy_en <= '1';
    elsif (CLK'event and CLK = '1') then
      if (reg_state = ST_EXE_WR) then
        if (reg_bus_rdy_en = '1') then
          reg_bus_wdata <= MCMD_RD_DAT;
        end if;
      end if;
      if (reg_state = ST_EXE_WR) then
        reg_bus_rdy_en <= BUS_READY;
      else
        reg_bus_rdy_en <= '1';
      end if;
    end if;
  end process;
  mux_bus_wdata <= MCMD_RD_DAT when (reg_bus_rdy_en = '1') else reg_bus_wdata;
  -- (READY='1'固定時は、最適化されてFFが消えるようにリセット初期値を設計)


  --エラー情報の保持
  process (in_RST_B, CLK)
  begin
    if (in_RST_B = '0') then
      reg_err   <= '0';
      reg_cmd_adr_err <= '0';
    elsif (CLK'event and CLK = '1') then
      reg_cmd_adr_err <= reg_cmd_addr(reg_cmd_addr'left);
      if (reg_state = ST_IDLE) then
        reg_err   <= '0';
      elsif (reg_state = ST_FETCH_CMD) then
        if (in_opcode_err = '1') then
          reg_err   <= '1';
        elsif ((reg_addr_cmd = '0') and (in_opcode_fin = '1')) then
          if ((0 /= reg_frm_len) and (G_FRAMELEN_EN = '1')) then
            reg_err   <= '1';
          end if;
        end if;
      elsif ((reg_state = ST_EXE_WR) or (reg_state = ST_EXE_RD)) then
        if ((0 = reg_frm_len) and (G_FRAMELEN_EN = '1')) then
          reg_err   <= '1';
        end if;
      else
        -- hold
      end if;
    end if;
  end process;

  -- コマンドアドレスエラーは、FFで叩いたものをチェックする
  in_cmd_adr_err <= reg_cmd_adr_err;
  --レスポンスアドレスエラーは、終端データ書き込みまで含めてチェックするので、次のアドレスでチェック
  in_rsp_adr_err <= nxt_rsp_addr_inc(reg_rsp_addr'left);
  --レスポンスライト時のエラーは、まさに書き込むアドレスがオーバーフローしたらエラーにする
  in_rsp_wr_err  <= reg_rsp_addr(reg_rsp_addr'left);


  -- レスポンスRAMへの書き戻し要求、アドレス制御
  process (in_RST_B, CLK)
  begin
    if (in_RST_B = '0') then
      reg_rsp_wr <= '0';
      reg_rsp_addr    <= (others => '0');
    elsif (CLK'event and CLK = '1') then
      if (ST_WR_RSP = reg_state) then
        reg_rsp_wr <= '1';
      elsif (reg_state = ST_EXE_RD) then
        if (in_bus_ready = '1') then
          reg_rsp_wr <= '1';
        end if;
      elsif (reg_state = ST_EXE_RDWAIT) then
        if (in_bus_ready = '1') then
          reg_rsp_wr <= '0';
        end if;
      else
        reg_rsp_wr <= '0';
      end if;

      if (reg_state = ST_IDLE) then
        if (EXEC_REQ = '1') then
          reg_rsp_addr <= in_rsp_sta_addr;
        end if;
      elsif (reg_state = ST_FETCH_CMD) then
        if (in_opcode_err = '1') then
          reg_rsp_addr <= (others => '0');
        end if;
      elsif (reg_state = ST_EXE_RD) then
        if (in_bus_ready = '1') then
          reg_rsp_addr <= nxt_rsp_addr_inc;
        end if;
      elsif ((reg_state = ST_WR_RSP) or (reg_state = ST_FIN)) then
        reg_rsp_addr <= nxt_rsp_addr_inc;
      else
        reg_rsp_addr <= reg_rsp_addr; -- hold
      end if;
    end if;
  end process;
  nxt_rsp_addr_inc  <= reg_rsp_addr + 1;

  process (reg_state, reg_seq_no, reg_rsp_addr, in_rsp_len, in_rsp_wr_err,
           reg_rsp_wr, BUS_READY, BUS_RD_DAT, reg_err, in_rsp_sta_addr)
  begin
    if (ST_WR_RSP = reg_state) then
      MRSP_WR     <= '1';
      MRSP_WR_DAT(15 downto 11) <= reg_seq_no & reg_err;
      MRSP_WR_DAT(10 downto reg_rsp_addr'left)  <= (others => '0');
      MRSP_WR_DAT(reg_rsp_addr'left-1 downto 0) <= in_rsp_len;
      MRSP_ADDR   <= in_rsp_sta_addr(MRSP_ADDR'left downto 0);
    elsif (ST_FIN = reg_state) then
      MRSP_WR     <= (not in_rsp_wr_err) and reg_rsp_wr;
      MRSP_WR_DAT <= (others => '1');
      MRSP_ADDR   <= reg_rsp_addr(reg_rsp_addr'left - 1 downto 0);
    else
      MRSP_WR     <= (not in_rsp_wr_err) and reg_rsp_wr and BUS_READY;
      MRSP_WR_DAT <= BUS_RD_DAT;
      MRSP_ADDR   <= reg_rsp_addr(reg_rsp_addr'left - 1 downto 0);
    end if;
  end process;


  -- 起動時のRAMアドレス指定に対応する
  GEN_EXEC_ADR_EN : if (G_EXEC_ADR_EN = '1') generate
    in_cmd_sta_addr  <= '0' & EXEC_CMD_ADR;
    in_rsp_sta_addr  <= '0' & EXEC_RSP_ADR;
    process (in_RST_B, CLK)
    begin
      if (in_RST_B = '0') then
        reg_rsp_len    <= (others => '0');
      elsif (CLK'event and CLK = '1') then
        if (reg_state = ST_IDLE) then
          reg_rsp_len <= (others => '0');
        elsif (reg_state = ST_FETCH_CMD) then
          if (in_opcode_err = '1') then
            reg_rsp_len <= (others => '0');
          end if;
        elsif (reg_state = ST_EXE_RD) then
          if (in_bus_ready = '1') then
            reg_rsp_len <= reg_rsp_len + 1;
          end if;
        elsif ((reg_state = ST_WR_RSP) or (reg_state = ST_FIN)) then
          reg_rsp_len <= reg_rsp_len + 1;
        else
          reg_rsp_len <= reg_rsp_len; -- hold
        end if;
      end if;
    end process;
    in_rsp_len   <= reg_rsp_len;
  end generate;

  -- 起動時のRAMアドレスは毎回0初期化する
  GEN_EXEC_ADR_OFF : if (G_EXEC_ADR_EN = '0') generate
    in_cmd_sta_addr <= (others => '0');
    in_rsp_sta_addr <= (others => '0');
    in_rsp_len      <= reg_rsp_addr(reg_rsp_addr'left-1 downto 0);
    reg_rsp_len     <= (others => '0');
  end generate;


  GEN_FRAMELEN_ON : if (G_FRAMELEN_EN = '1') generate
    --フレーム長のチェックは、有効時のみ行う
    process (in_RST_B, CLK)
    begin
      if (in_RST_B = '0') then
        reg_frm_len  <= (others => '0');
      elsif (CLK'event and CLK = '1') then
        case reg_state is
        when ST_IDLE =>
          reg_frm_len  <= (others => '0');
        when ST_RD_HEAD =>
          reg_frm_len  <= MCMD_RD_DAT(10 downto 0);
        when ST_FETCH_CMD =>
          if (reg_addr_cmd = '0') then
            if (in_opcode_2w = '1') then
              --連続アクセス
              reg_frm_len  <= nxt_frm_len_dec;
            else
              --単発アクセス or 終端(Don't care)
              if (in_opcode_rw = '1') then
                --ライトコマンド
                reg_frm_len  <= nxt_frm_len_dec;
              end if;
            end if;
          else
            if (reg_rw_cmd = '1') then
              --ライトコマンド
              reg_frm_len  <= nxt_frm_len_dec;
            end if;
          end if;
        when ST_EXE_WR =>
          if (in_bus_ready = '1') then
            reg_frm_len  <= nxt_frm_len_dec;
          end if;
        when ST_EXE_RDWAIT =>
          if (in_bus_ready = '1') then
            reg_frm_len  <= nxt_frm_len_dec;
          end if;
        when others  =>
          reg_frm_len  <= reg_frm_len; -- hold
        end case;
      end if;
    end process;

    -- 0になるまでダウンカウントするが、0で停止。
    nxt_frm_len_dec <= reg_frm_len when (0 = reg_frm_len) else (reg_frm_len - 1);
  end generate;

  GEN_FRAMELEN_OFF : if (G_FRAMELEN_EN = '0') generate
    reg_frm_len     <= (others => '0');
    nxt_frm_len_dec <= (others => '0');
  end generate;

  -- シーケンスNo保持用ライト信号
  GEN_SEQ_CHECK_ON : if (G_SEQ_CHK_EN = '1') generate
    process (in_RST_B, CLK)
    begin
      if (in_RST_B = '0') then
        reg_seq_wr <= '0';
      elsif (CLK'event and CLK = '1') then
        if ((reg_state = ST_RD_HEAD) and (reg_addr_cmd = '0')) then
          reg_seq_wr <= '1';
        else
          reg_seq_wr <= '0';
        end if;
      end if;
    end process;
  end generate;

  GEN_SEQ_CHECK_OFF : if (G_SEQ_CHK_EN = '0') generate
    reg_seq_wr <= '0';
  end generate;


  SEQ_NO_WR   <= reg_seq_wr;
  SEQ_NO_WDAT <= reg_seq_no;

  in_exec_busy <= '0' when (reg_state = ST_IDLE) else '1';

  EXEC_BUSY   <= in_exec_busy;
  EXEC_FIN    <= '1' when (ST_FIN = reg_state) else '0';
  EXEC_ERR    <= reg_err;

  MCMD_CS     <= in_exec_busy;
  MRSP_CS     <= in_exec_busy;
  MCMD_ADDR   <= reg_cmd_addr(reg_cmd_addr'left - 1 downto 0);

  BUS_WR_REQ  <= '1' when (reg_state = ST_EXE_WR) else '0';
  BUS_RD_REQ  <= '1' when (reg_state = ST_EXE_RD) else '0';
  BUS_ADDR    <= reg_bus_addr;
  BUS_WR_DAT  <= mux_bus_wdata;

endmodule

`default_nettype wire
