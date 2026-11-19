SECTIONS {
  /DISCARD/ : {
    *(.eh_frame)
    *(.eh_frame_hdr)
    *(.gcc_except_table*)
  }
} INSERT AFTER .comment;
