###
##
## NAME
##
## plot_coverage.r
##
## AUTHOR
##
## Jeffrey E. Barrick <jeffrey.e.barrick@gmail.com>
##
## LICENSE AND COPYRIGHT
##
## Copyright (c) 2010 Michigan State University
##
## breseq is free software; you can redistribute it and/or modify it under the terms the 
## GNU General Public License as published by the Free Software Foundation; either 
## version 1, or (at your option) any later version.
##
###

## Arguments:
##   in_file=/path/to/input 
##   out_file=/path/to/output 
##   window_start=int
##   window_end=int
##   end_pos=int
##   pdf_output=0 or 1
##   total_only=0 or 1

window_start = -1;
window_end = -1;
pdf_output = 0;
total_only = 0;

for (e in commandArgs()) {
  ta = strsplit(e,"=",fixed=TRUE)
  if(! is.na(ta[[1]][2])) {
    temp = ta[[1]][2]
 #   temp = as.numeric(temp) #Im only inputting numbers so I added this to recognize scientific notation
    if(substr(ta[[1]][1],nchar(ta[[1]][1]),nchar(ta[[1]][1])) == "I") {
      temp = as.integer(temp)
    }
    if(substr(ta[[1]][1],nchar(ta[[1]][1]),nchar(ta[[1]][1])) == "N") {
      temp = as.numeric(temp)
    }
    assign(ta[[1]][1],temp)
    cat("assigned ",ta[[1]][1]," the value of |",temp,"|\n")
  } else {
    assign(ta[[1]][1],TRUE)
    cat("assigned ",ta[[1]][1]," the value of TRUE\n")
  }
}

window_start = as.numeric(window_start);
window_end = as.numeric(window_end);

X<-read.table(in_file, sep="\t", header=T)
X$unique_tot_cov = X$unique_bot_cov + X$unique_top_cov;
X$redundant_tot_cov = X$redundant_bot_cov + X$redundant_top_cov;
maxy=max(X$unique_tot_cov, X$redundant_tot_cov) + 5;
start_pos = X$position[1];
end_pos = X$position[length(X$position)];

if (window_start == -1)
{
	window_start = start_pos;
}
if (window_end == -1)
{
	window_end = end_pos;
}

if (pdf_output == 0) {
	## taa=4, gaa=2 options NOT compatible with earlier R versions!
	## units = "px" NOT compatible with even earlier R versions!
	bitmap(out_file, height=6, width=11, type = "png16m", res = 72, pointsize=16)
} else {
	pdf(out_file, height=6, width=11)
}

### We use a blank graph for the legend!!
par(mar=c(4.1,5.1,1.1,1.1));
layout(matrix(c(1,2), 2, 1, byrow = TRUE), heights=c(5,0.65))

plot(0:10, 0:10, type="n", lty="solid", ylim=c(0, maxy), xlim=c(start_pos, end_pos), lwd=2, xaxs="i", yaxs="i", xlab="Coordinate in Reference Genome", ylab="Read Coverage Depth")

#### Need to add back the option to gray out the ends!
rect(start_pos, 0, window_start, maxy, col="grey85", lty=0)
rect(window_end+1, 0, end_pos, maxy, col="grey85", lty=0)

lines(X$position, X$redundant_tot_cov, type="s", col="red", lty="solid", lwd=1.5 )
if (total_only == 0)
{
	lines(X$position, X$redundant_top_cov, type="s", col="yellow", lty="solid", lwd=0.7)
	lines(X$position, X$redundant_bot_cov, type="s", col="orange", lty="solid", lwd=0.7)
}

lines(X$position, X$unique_tot_cov, type="s", col="blue", lty="solid", lwd=1.5 )
if (total_only == 0)
{
	lines(X$position, X$unique_top_cov, type="s", col="cyan", lty="solid", lwd=0.7)
	lines(X$position, X$unique_bot_cov, type="s", col="purple", lty="solid", lwd=0.7)
}

## draw a legend
par(mar=c(0.5,3,0.1,0.5));
barplot(0,0, axes=FALSE)

if (total_only == 0) {
	legend( "bottom" , cex=0.75, c("unique total", "unique top", "unique bottom ", "repeat total", "repeat top","repeat bottom"), pch=-1, horiz=T, col="black", fill=c("blue", "cyan", "purple", "red", "yellow", "orange"), bty="n")
} else {
	legend( "bottom" , cex=0.85, c("unique total", "repeat total"), pch=-1, horiz=T, col="black", fill=c("blue", "red"), bty="n")
}



dev.off()