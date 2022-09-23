//--------------------------------------------------------------------------------------------------
//! Module: **Ether PHY RMII 受信モジュール**
//--------------------------------------------------------------------------------------------------
// Revisions  :
// Date        Version  Author            Comment
// 2022/05/12  0.01     Akihisa.Ogata     初期作成
//
//--------------------------------------------------------------------------------------------------
//!
//! プリアンブル受信開始から受信処理を開始するが、プリアンブルは受信データとして出てこない。<br>
//! ただし、CRC(32bit)は、受信データとして4byte分RX_RCVがONする。その間は、データ分部かどうかも判別できない。<br>
//! そのため、上位側で4byteが不要なら破棄すること。CRCチェックの結果はRX_ERRORのアサートで判定できる。<br>
//! **ERR_FCT(2:0)要因詳細**
//! | bit  | 要因 |
//! | :--- | :--- |
//! | bit0 | プリアンブル異常 |
//! | bit1 | データニブル数異常 |
//! | bit2 | CRC不一致 |
//!
//! **Timing Chart**
//! { head:{
//!     text:'Receive Control signals',
//!   },
//!   signal: [
//!     {   name:'CLK',      wave:'p.|.............|...', period:1},
//!     ['Control',
//!       { name:'RX_RCV',   wave:'0.|.......10..10|10.' },
//!       { name:'RX_DATA',  wave:'x.|.......=x..=x|=x.', data:["Dat0","Dat1","CRC"] },
//!       { name:'RX_BUSY',  wave:'0.|...1...|..|....0.', node: '......b...........d' },
//!       { name:'RX_DONE',  wave:'0.|.......|..|....10' },
//!       { name:'RX_ERROR', wave:'0.|.......|..|....20' },
//!     ],
//!     {},
//!     ['RMII',
//!       { name:'MII_RX_DV',wave:'01|.......|..|0....', node: '..............c'},
//!       { name:'MII_RX_D', wave:'x=|.=...=.|=.|x....', data:["preamble","Dat0","Dat1","CRC"], node: '....a.'},
//!     ],
//!   ],
//!   edge: [
//!    'a~>b','c~>d'
//!   ],
//! }
`default_nettype none

module ethphy_rmii_rx
  # (
    parameter P_CHK_FCS = 1'b1, //! FCS(CRC)チェックを行う
    parameter P_RST_ACT = 1'b0  //! リセット論理 (1:正論理リセット / 0:負論理リセット)
  ) (
    input  wire       RST_B,      //! 非同期リセット
    input  wire       CLK,        //! 50MHzクロック(RMII Master CLK)
    // (制御IF信号)
    output wire       RX_BUSY,    //! 受信Busy
    output wire       RX_RCV,     //! 受信データ到着(1clk'H')
    output wire [7:0] RX_DATA,    //! 受信データ
    output wire       RX_DONE,    //! 受信完了
    output wire       RX_ERROR,   //! DONEと同時にアサートでエラー
    output wire [2:0] RX_ERR_FCT, //! エラー要因カウント用(1clk'H')
    // (外部端子)
    input  wire       MII_RX_ER,  //! RMII RX_ER
    input  wire       MII_RX_DV,  //! RMII RX_DV
    input  wire [1:0] MII_RX_D    //! RMII RXD
  );

  // リセット正論理指定では、リセット入力を反転
  wire in_RST_B = P_RST_ACT ? ~RST_B : RST_B;
  
  //====== ステートマシン ============================================
  localparam [1:0] ST_RX_IDLE   =2'b00,
                   ST_RX_PREAMB =2'b01,
                   ST_RX_DATA   =2'b11,
                   ST_RX_END    =2'b10;
  reg  [1:0]  reg_State;
  reg         reg_Busy;
  reg         reg_Done;
  reg         reg_Sucs;
  reg  [2:0]  reg_ErrFct;

  reg  [31:0] reg_RxData;
  reg         reg_RxValid;
  reg         reg_RxErrLatch;
  reg  [4:0]  reg_DataCnt;

  reg  [1:0]  reg_RmiiData;
  reg         reg_RmiiRxDv;
  reg         reg_RmiiRxErr;
  reg  [1:0]  reg_RxData_If;
  reg         reg_RxDv_If;
  reg         reg_RxErr_If;

  wire in_crc_correct;

  generate
    if (P_CHK_FCS) begin
      reg         reg_crc_add;
      wire [31:0] in_crc_out;
      wire in_crc_init = ((reg_State == ST_RX_IDLE) || (reg_State == ST_RX_PREAMB));

      phy_eth_crc # (
        .P_DEFAULT(32'hFFFFFFFF),
        .P_RST_ACT(P_RST_ACT)
      )
      U_crc (
        .RST_B(RST_B),
        .CLK(CLK),
        .CRC_INIT(in_crc_init),
        .DATA_ADD(reg_crc_add),
        .DATA_IN(reg_RxData[3:0]),
        .OUT_CRC(in_crc_out)
      );
      assign in_crc_correct = (in_crc_out == (~reg_RxData[31:0]));
    
      reg  reg_CrcDly;
      always @(posedge CLK or negedge in_RST_B) begin
        if (!in_RST_B) begin
          reg_CrcDly   <= 1'b0;
          reg_crc_add <= 1'b0;
        end
        else begin
          if (reg_State == ST_RX_DATA) begin
            if (reg_DataCnt[3:0]==4'b1110) begin
              reg_CrcDly <= 1'b1;
            end
          end
          else begin
            reg_CrcDly <= 1'b0;
          end
    
          if (reg_DataCnt[0]) begin
            reg_crc_add <= (reg_RxDv_If & reg_CrcDly);
          end
          else begin
            reg_crc_add <= 1'b0;
          end
    
        end
      end

    end
    else begin  // !(P_CHK_FCS) 
      assign in_crc_correct = 1'b1;

    end
  endgenerate


  // メインステートマシン
  always @(posedge CLK or negedge in_RST_B) begin
    if (!in_RST_B) begin
      reg_State      <= ST_RX_IDLE;
      reg_RxValid    <= 1'b0;
      reg_RxErrLatch <= 1'b0;
      reg_DataCnt  <= 5'd0;
      reg_Busy     <= 1'b0;
      reg_Sucs     <= 1'b0;
      reg_Done     <= 1'b0;
      reg_ErrFct   <= 3'b000;
    end
    else begin
      case (reg_State)
        ST_RX_IDLE : begin
          reg_Busy <= 1'b0;
          reg_Sucs <= 1'b0;
          reg_Done <= 1'b0;
          if (reg_RxDv_If && (reg_RxData_If == 2'b01)) begin
            //プリアンブル受信開始
            reg_State <= ST_RX_PREAMB;
          end
          //プリアンブル以外で受信開始した場合は、無視して待機
          reg_DataCnt <= 5'd0;
          reg_ErrFct  <= 3'b000;
        end

        ST_RX_PREAMB : begin
          reg_Sucs  <= 1'b0;
          reg_Done  <= 1'b0;
          reg_ErrFct[0] <= 1'b1;
          if (reg_RxDv_If) begin
            if (reg_RxData_If == 2'b11) begin // プリアンブルの最後
              if (reg_DataCnt[0] || (reg_DataCnt <= 5'd16)) begin
                reg_State <= ST_RX_END; // 不正なビットパタンはエラー
              end
              else begin
                // 2bit偶数個でNibbleが成立。Odd Nibbleは許容。5byte以上のプリアンブルで受信許可
                reg_State <= ST_RX_DATA;
                reg_Busy  <= 1'b1;
              end
              reg_DataCnt <= 5'd0;
            end
            else if (reg_RxData_If == 2'b01) begin // プリアンブルの途中
              // hold state and count.
              if (reg_DataCnt != 5'b11111) begin
                reg_DataCnt <= reg_DataCnt + 5'd1;
              end
            end
            else begin
              reg_State <= ST_RX_END; // 不正なビットパタンはエラー
            end
          end
          else begin
            reg_State <= ST_RX_END; // 不正にRX_DVが落ちたらエラー(RX_ERがアサートしたかも)
          end
        end

        ST_RX_DATA : begin
          reg_ErrFct[0] <= 1'b0;
          if (!reg_RxDv_If) begin
            if (reg_DataCnt[1:0] == 2'b00) begin
              //受信ビット数正常. CRC照合結果をラッチ
              reg_Sucs  <= in_crc_correct;
              reg_ErrFct[2] <= (~in_crc_correct);
            end
            else begin
              //受信ビット数がおかしい場合。エラー
              reg_ErrFct[1] <= 1'b1;
            end
            reg_State <= ST_RX_END;
            reg_Busy  <= 1'b0;
            reg_Done  <= 1'b1;
          end
          reg_DataCnt <= reg_DataCnt + 5'd1;
        end

        ST_RX_END : begin
          reg_DataCnt  <= 5'd0;
          reg_ErrFct   <= 3'b000;
          reg_Busy     <= 1'b0;
          reg_Done     <= 1'b0;
          reg_Sucs     <= 1'b0;
          if (!reg_RxDv_If) begin
            reg_State <= ST_RX_IDLE;
          end
        end

        default : begin
          reg_State <= ST_RX_END; // マイナループ対策
        end
      endcase

      if (reg_RxValid) begin
        reg_RxValid <= 1'b0;
      end
      else begin
        if (reg_DataCnt[1:0] == 2'b11) begin
          reg_RxValid <= (reg_RxDv_If & reg_Busy);
        end
      end

      if ((reg_State == ST_RX_IDLE) || (reg_State == ST_RX_END)) begin
        reg_RxErrLatch <= 1'b0;
      end
      else if (!reg_RxErrLatch) begin
        reg_RxErrLatch <= reg_RxErr_If;
      end
    end
  end
  

  always @(posedge CLK or negedge in_RST_B) begin
    if (!in_RST_B) begin
      reg_RxData <= 32'h0;      
    end
    else begin
      if ((reg_State == ST_RX_DATA) && reg_RxDv_If) begin
        reg_RxData  <= {reg_RxData_If & reg_RxData[31:2]};
      end
    end
  end

  assign RX_RCV   = reg_RxValid;
  assign RX_DATA  = reg_RxData[31:24];
  assign RX_BUSY  = reg_Busy;
  assign RX_DONE  = reg_Done;
  assign RX_ERROR = ((!reg_Sucs) || reg_RxErrLatch) && reg_Done;
  assign RX_ERR_FCT = (reg_State == ST_RX_END) ? reg_ErrFct : 3'b000;


  // 端子とのIF信号
  // (クロック同期入力だが、FFの配置の自由度を上げ、念のためメタス伝搬を抑えるため、
  //  2段FF受けとする)
  always @(posedge CLK or negedge in_RST_B) begin
    if (!in_RST_B) begin
      reg_RxData_If <= 2'b00;
      reg_RxDv_If   <= 1'b0;
      reg_RxErr_If  <= 1'b0;
    end
    else begin
      // 内部参照FF
      reg_RxData_If <= reg_RmiiData;
      reg_RxDv_If   <= reg_RmiiRxDv;
      reg_RxErr_If  <= reg_RmiiRxErr;
    end
  end

  always @(posedge CLK or negedge in_RST_B) begin
    if (!in_RST_B) begin
      reg_RmiiData  <= 2'b00;
      reg_RmiiRxDv  <= 1'b0;
      reg_RmiiRxErr <= 1'b0;
    end
    else begin
      // 外部端子受けFF
      reg_RmiiData  <= MII_RX_D;
      reg_RmiiRxDv  <= MII_RX_DV;
      reg_RmiiRxErr <= MII_RX_ER;
    end  
  end

endmodule

`default_nettype wire
