import gzip
import matplotlib.pyplot as plt
import numpy
import sys
import re

data_azerr = {
    'average': [], 'median': [], 'min': [], 'max': [], 'stdev': [], 'maxamp': [], 'maxinterval': [], 'n': [],
    'classification': []
}
data_elerr = {
    'average': [], 'median': [], 'min': [], 'max': [], 'stdev': [], 'maxamp': [], 'maxinterval': [], 'n': [],
    'classification': []
}

colourMapping = { 'g': "black", 'o': "yellow", 's': "blue", 'b': "red", 'c': "green" };

# For each file supplied as an argument, read the file in.
for i in xrange(1, len(sys.argv)):
    f = sys.argv[i]
    print "Reading file %s" % sys.argv[i]

    with gzip.open(f, 'rb') as fin:
        file_content = fin.read()

    # Split the file into lines.
    file_lines = file_content.split("\n")
    
    # Parse the data.
    current_data = None
    for l in file_lines:
        if (l == 'AZ ERROR'):
            current_data = data_azerr
        elif (l == 'EL ERROR'):
            current_data = data_elerr
        c = re.split("\s+", l)
        if (current_data is not None and c[0] == "" and len(c) == 3):
            v = float(c[2])
            t = re.sub(':', '', c[1])
            current_data[t].append(v)
        elif (c[0] == "classification:"):
            vs = re.split("\,", c[1])
            data_azerr['classification'].append(colourMapping[vs[0]])
            data_elerr['classification'].append(colourMapping[vs[1]])

        
# Now make some plots.
plt.scatter(data_azerr['average'], data_azerr['stdev'], c=data_azerr['classification'])
#plt.ion()
plt.show()
