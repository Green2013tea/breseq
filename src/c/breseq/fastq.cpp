/*****************************************************************************
 
 AUTHORS
 
 Jeffrey E. Barrick <jeffrey.e.barrick@gmail.com>
 David B. Knoester
 
 LICENSE AND COPYRIGHT
 
 Copyright (c) 2010 Michigan State University
 
 breseq is free software; you can redistribute it and/or modify it under the  
 terms the GNU General Public License as published by the Free Software 
 Foundation; either version 1, or (at your option) any later version.
 
 *****************************************************************************/


#include "breseq/fastq.h"

namespace breseq {

  //constructor
  cFastqFile::cFastqFile(const std::string &file_name, const std::string &out_file_name, std::ios_base::openmode mode) :
    m_max_read_length(0),
    m_min_quality_score(INT_MAX),
    m_max_quality_score(0),
    m_total_base(0), 
    m_total_reads(0), 
    m_file(file_name.c_str(), mode), 
    m_outfile(out_file_name.c_str(), std::fstream::in) { }
  
  //check to make sure certain conditions about the data are fulfilled
  void cFastqFile::error_in_file_format(int count, int num_reads, int position) {
    int n;

    
    if( count != 4 )
      fprintf(stderr, "Your file is not formatted correctly in line: %d ", (4*num_reads)+count+1);

    switch (count) {
      case 0:
        fprintf(stderr, "\nThis line should be the name of the read and start with '@'. ");
        fprintf(stderr, "\nEither a line is missing or there is no '@' in the read name.\n");
        break;
      case 1:
        fprintf(stderr, "at position: %d", position+1);
        fprintf(stderr, "\nThis should be a type of base ('A', 'T', 'G', 'C', or 'N')... it is not. ");
        fprintf(stderr, "\nEither a line is missing or there is an unknown nucleotide type on this line.\n");
        break;
      case 2:
        fprintf(stderr, "\nThis should be a '+' and only a '+'. Either a line is missing of there is an unknown symbol here.\n");
        break;
      case 3:
        fprintf(stderr, "\nThe sequence and score lines are not the same length.\n");
        break;
      case 4:
        fprintf(stderr, "Your file is not formatted correctly in line: %d ", (4*num_reads)+count-2);
        fprintf(stderr, "... at position %d you have an illegal whitespace character.  If it is at the end of a line, it is probably an extra \\r at the end of every line.\n", position+1);
        break;
    }
    fprintf(stderr, "\nNow I'm quitting.\n\n");
    exit(-1);
    
  }
  
  //make sure the file opened... if not it will fail
  void cFastqFile::check_if_file_opened() {
    assert(m_file.is_open());
  }
  
  void cFastqFile::read_sequence(cFastqSequence &sequence) {
    
    std::string line, longest_read("");
    uint8_t max_score(0), min_score(UINT8_MAX);
    uint32_t num_reads(0), num_bases(0);
    
    if ( m_file.is_open() ) {
      while( getline( m_file, line )) {
        int count(0);
        
        //parse the read to get the 4 read parameters
        while( count < 4 ) {
          switch (count) {
            case 0:
              sequence.m_name = line;
              getline(m_file, line);
              count++;
            case 1:
              sequence.m_sequence = line;
              getline(m_file, line);
              count++;
            case 2:
              sequence.m_blank = line;
              getline(m_file, line);
              count++;
            case 3:
              sequence.m_qualities = line;
              count++;
              break;
            default:
              error_in_file_format(count, num_reads, 0);
          }
        }
        
        //Error Checking
        {
          if( sequence.m_name[0] != '@' ) error_in_file_format(count-4, num_reads, 0);
          
          for (uint16_t i=0; i<sequence.m_sequence.size(); i++) {
            if( isspace(sequence.m_sequence[i]) ) error_in_file_format(count, num_reads, i);
          }
          
          for (uint32_t i=0; i<sequence.m_sequence.size(); i++) {
            if(sequence.m_sequence[i] != 'A' && 
               sequence.m_sequence[i] != 'T' && 
               sequence.m_sequence[i] != 'G' && 
               sequence.m_sequence[i] != 'C' && 
               sequence.m_sequence[i] != 'N') {
               error_in_file_format(count-3, num_reads, i);
            }
          }
        
          if( sequence.m_blank[0] != '+' ) error_in_file_format(count-2, num_reads, 0);
          
          if( sequence.m_sequence.size() != sequence.m_qualities.size() ) error_in_file_format(count-1, num_reads, 0);
        }
        
        //increment read number
        num_reads++;
        
        //check sequence length
        if( sequence.m_sequence.size() > longest_read.size() ) longest_read = line;
        
        //add current sequence length to number of bases
        num_bases += sequence.m_sequence.size();
        
        //iterate through sequence grabbing the associated scores
        //if the two are not the same length it should be caught in error checking
        for (uint32_t i=0; i<sequence.m_qualities.size(); i++) {
          int this_score(uint8_t(sequence.m_qualities[i]));
          if( this_score > max_score ) max_score = this_score;
          if( this_score < min_score ) min_score = this_score;
        }
        
      }  

    }
    //final assignments
    m_total_reads = num_reads;
    m_total_base = num_bases;
    m_max_read_length = longest_read.size();
    m_min_quality_score = min_score-33;
    m_max_quality_score = max_score-33;
  }

  void cFastqFile::write_sequence(cFastqSequence &sequence) {
    // don't need to implement in first stage
  }
  
  void cFastqFile::write_summary_file() {
    
    // Should have lines like: max_read_length 36
    //                         num_reads 1020200
    //                         min_quality_score 4
    //                         max_quality_score 40
    //                         num_bases 62646176
    std::cout << "max_read_length "   << m_max_read_length   << std::endl;
    std::cout << "num_reads "         << m_total_reads       << std::endl;
    std::cout << "min_quality_score " << m_min_quality_score << std::endl;
    std::cout << "max_quality_score " << m_max_quality_score << std::endl;
    std::cout << "num_bases "         << m_total_base        << std::endl;
  }
  
} // breseq namespace

