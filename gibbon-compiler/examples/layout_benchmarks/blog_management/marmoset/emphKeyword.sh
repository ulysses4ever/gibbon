#INCLUDE= -I/local/scratch/a/singhav/Applications/src/uthash-2.3.0/include/
INCLUDE=

gibbon --packed --no-gc --toC layout1.hs; gcc $INCLUDE -O3 layout1.c  -o layout1

gibbon --packed --no-gc --toC layout2.hs; gcc $INCLUDE -O3 layout2.c  -o layout2

gibbon --packed --no-gc --toC layout3.hs; gcc $INCLUDE -O3 layout3.c  -o layout3 

gibbon --packed --no-gc --toC layout4.hs; gcc $INCLUDE -O3 layout4.c  -o layout4 

gibbon --packed --no-gc --toC layout5.hs; gcc $INCLUDE -O3 layout5.c  -o layout5 

gibbon --packed --no-gc --toC layout6.hs; gcc $INCLUDE -O3 layout6.c  -o layout6 

gibbon --packed --no-gc --toC layout7.hs; gcc $INCLUDE -O3 layout7.c  -o layout7 

gibbon --packed --no-gc --toC layout8.hs; gcc $INCLUDE -O3 layout8.c  -o layout8

./layout1
./layout2 
./layout3 
./layout4
./layout5
./layout6
./layout7
./layout8

rm layout1
rm layout2 
rm layout3 
rm layout4 
rm layout5 
rm layout6 
rm layout7 
rm layout8
