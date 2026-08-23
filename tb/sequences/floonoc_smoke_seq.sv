// -----------------------------------------------------------------------------
// Smoke sequence: 10 deterministic directed flits (every input port and
// every output direction at least once), followed by NumRandom
// constrained-random legal flits.
// -----------------------------------------------------------------------------
class floonoc_smoke_seq extends uvm_sequence #(floonoc_flit_item);

  `uvm_object_utils(floonoc_smoke_seq)

  int unsigned num_random = 15;

  // src_port, dst_x, dst_y — each row justified in docs/verification_plan.md.
  // Directions: North=0 East=1 South=2 West=3 Eject=4; router at (1,1).
  typedef struct {
    int unsigned src;
    bit [1:0]    x;
    bit [1:0]    y;
  } directed_t;

  localparam directed_t DirectedFlits [10] = '{
    '{4, 2'd2, 2'd1},  // Eject -> East
    '{4, 2'd0, 2'd1},  // Eject -> West
    '{4, 2'd1, 2'd2},  // Eject -> North
    '{4, 2'd1, 2'd0},  // Eject -> South
    '{0, 2'd1, 2'd1},  // North -> Eject
    '{0, 2'd1, 2'd0},  // North -> South
    '{1, 2'd0, 2'd1},  // East  -> West
    '{2, 2'd1, 2'd2},  // South -> North
    '{3, 2'd2, 2'd1},  // West  -> East
    '{3, 2'd1, 2'd1}   // West  -> Eject
  };

  function new(string name = "floonoc_smoke_seq");
    super.new(name);
  endfunction

  virtual task body();
    floonoc_flit_item item;

    // Phase 1: deterministic directed traffic
    foreach (DirectedFlits[i]) begin
      item = floonoc_flit_item::type_id::create($sformatf("directed_%0d", i));
      start_item(item);
      item.src_port = DirectedFlits[i].src;
      item.dst_x    = DirectedFlits[i].x;
      item.dst_y    = DirectedFlits[i].y;
      item.payload  = payload_t'(64'hFACE_0000_0000_0000 + 64'(i));
      finish_item(item);
      `uvm_info("SEQ", {"directed: ", item.convert2string()}, UVM_MEDIUM)
    end

    // Phase 2: constrained-random legal traffic
    repeat (num_random) begin
      item = floonoc_flit_item::type_id::create("rand_item");
      start_item(item);
      if (item.randomize() == 0) begin
        `uvm_error("SEQ", "randomize() failed")
      end
      finish_item(item);
      `uvm_info("SEQ", {"random:   ", item.convert2string()}, UVM_MEDIUM)
    end
  endtask

endclass : floonoc_smoke_seq
