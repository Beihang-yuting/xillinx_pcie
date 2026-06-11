//=============================================================================
// 共享内存应答器：收访存请求 → 访本地 host_mem_manager → 返回 CplD（宿主发送）
// MWr(posted,无回复) / MRd / MRdLk / Atomic(FetchAdd/Swap/CAS)
//
// Note: host_mem_manager lives in $unit scope and cannot be named inside a
//       package in VCS.  We hold a host_mem_api handle (declared in
//       host_mem_pkg, which this package imports) and rely on virtual dispatch
//       to call write_mem / read_mem on the concrete host_mem_manager object.
//=============================================================================
class xilinx_pcie_mem_responder;

    host_mem_api mem;            // 本 agent 的内存实例（host_mem_manager 实现）
    bit [15:0]   completer_id;

    function new(host_mem_api mem = null, bit [15:0] completer_id = 16'h0);
        this.mem          = mem;
        this.completer_id = completer_id;
    endfunction

    function void from_bytearr(input byte src[], output bit [7:0] dst[]);
        dst = new[src.size()];
        foreach (src[i]) dst[i] = src[i];
    endfunction

    // 返回需发出的 CplD（无需回复返回 null）
    function pcie_tl_cpl_tlp handle_mem_request(pcie_tl_tlp req);
        pcie_tl_mem_tlp    mem_req;
        pcie_tl_atomic_tlp atm_req;
        if (mem == null) return null;
        if (req.kind == TLP_MEM_WR) begin
            if ($cast(mem_req, req)) write_with_be(mem_req);
            return null;
        end
        if (req.kind == TLP_MEM_RD || req.kind == TLP_MEM_RD_LK) begin
            if (!$cast(mem_req, req)) return null;
            return build_read_cpl(mem_req, (req.kind==TLP_MEM_RD_LK)?TLP_CPLD_LK:TLP_CPLD);
        end
        if (req.kind inside {TLP_ATOMIC_FETCHADD, TLP_ATOMIC_SWAP, TLP_ATOMIC_CAS}) begin
            if ($cast(atm_req, req)) return build_atomic_cpl(atm_req);
            return null;
        end
        return null;
    endfunction

    protected function void write_with_be(pcie_tl_mem_tlp r);
        int total_dw = (r.payload.size() + 3) / 4;
        int idx = 0;
        for (int dw = 0; dw < total_dw; dw++) begin
            bit [3:0] be = (dw==0) ? r.first_be :
                           (dw==total_dw-1 && total_dw>1) ? r.last_be : 4'hF;
            for (int b = 0; b < 4; b++) begin
                if (idx < r.payload.size()) begin
                    if (be[b]) begin
                        byte one[]; one = new[1]; one[0] = byte'(r.payload[idx]);
                        mem.write_mem(r.addr + idx, one, `__FILE__, `__LINE__);
                    end
                    idx++;
                end
            end
        end
    endfunction

    protected function pcie_tl_cpl_tlp build_read_cpl(pcie_tl_mem_tlp r, tlp_kind_e k);
        pcie_tl_cpl_tlp  cpl; byte rd[];
        int unsigned     rlen;
        rlen = (r.length == 0) ? 32'd4096 : ({22'd0, r.length} * 4);
        mem.read_mem(r.addr, rlen, rd, `__FILE__, `__LINE__);
        cpl = pcie_tl_cpl_tlp::type_id::create("mem_cpl");
        cpl.kind=k; cpl.fmt=FMT_3DW_WITH_DATA;
        cpl.requester_id=r.requester_id; cpl.tag=r.tag; cpl.completer_id=completer_id;
        cpl.cpl_status=CPL_STATUS_SC; cpl.length=r.length;
        cpl.byte_count=rlen[11:0]; cpl.lower_addr=r.addr[6:0];
        from_bytearr(rd, cpl.payload);
        return cpl;
    endfunction

    protected function pcie_tl_cpl_tlp build_atomic_cpl(pcie_tl_atomic_tlp r);
        pcie_tl_cpl_tlp  cpl; byte oldb[]; byte newb[];
        int unsigned     sz;
        sz = r.is_64bit ? 32'd8 : 32'd4;
        mem.read_mem(r.addr, sz, oldb, `__FILE__, `__LINE__);
        compute_atomic(r, oldb, int'(sz), newb);
        mem.write_mem(r.addr, newb, `__FILE__, `__LINE__);
        cpl = pcie_tl_cpl_tlp::type_id::create("atomic_cpl");
        cpl.kind=TLP_CPLD; cpl.fmt=FMT_3DW_WITH_DATA;
        cpl.requester_id=r.requester_id; cpl.tag=r.tag; cpl.completer_id=completer_id;
        cpl.cpl_status=CPL_STATUS_SC;
        cpl.length=sz[9:0]/4; cpl.byte_count=sz[11:0]; cpl.lower_addr=r.addr[6:0];
        from_bytearr(oldb, cpl.payload);
        return cpl;
    endfunction

    // operand=payload[0..sz-1]; CAS: compare=payload[0..sz-1], swap=payload[sz..2sz-1]
    protected function void compute_atomic(pcie_tl_atomic_tlp r, input byte oldb[],
                                           input int sz, output byte newb[]);
        longint unsigned oldv=0, opnd=0, cmp=0, swp=0, nv=0;
        newb = new[sz];
        for (int i=0;i<sz;i++) oldv |= (longint'(oldb[i]) & 64'hFF) << (8*i);
        for (int i=0;i<sz;i++) if (i<r.payload.size()) opnd |= (longint'(r.payload[i]) & 64'hFF) << (8*i);
        case (r.kind)
            TLP_ATOMIC_FETCHADD: nv = oldv + opnd;
            TLP_ATOMIC_SWAP:     nv = opnd;
            TLP_ATOMIC_CAS: begin
                for (int i=0;i<sz;i++) begin
                    if (i<r.payload.size())     cmp |= (longint'(r.payload[i])    & 64'hFF) << (8*i);
                    if (sz+i<r.payload.size())  swp |= (longint'(r.payload[sz+i]) & 64'hFF) << (8*i);
                end
                nv = (oldv==cmp) ? swp : oldv;
            end
            default: nv = oldv;
        endcase
        for (int i=0;i<sz;i++) newb[i] = byte'((nv >> (8*i)) & 64'hFF);
    endfunction

endclass
