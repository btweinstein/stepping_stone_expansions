#cython: profile=False
#cython: boundscheck=False
#cython: initializedcheck=False
#cython: nonecheck=False
#cython: wraparound=False
#cython: cdivision=True

# Things will actually crash if nonecheck is set to true...as neighbors is initially set to none

__author__ = 'bryan'

cimport cython
import numpy as np
cimport numpy as np
import random
import sys
from libcpp cimport bool
from matplotlib import animation
import matplotlib.pyplot as plt
import pandas as pd

from cython_gsl cimport *
from libc.stdlib cimport free

cdef class Individual:
    '''All individuals have the same motility and mutation rate for now, but can have different selective advantages.'''
    cdef readonly long allele_id
    # Note that all rates should be non-dimensionalized in terms of generation time
    cdef readonly double growth_rate
    cdef readonly double mutation_rate

    def __init__(Individual self, long allele_id, growth_rate = 1.0, mutation_rate = 0.0):
        self.allele_id = allele_id
        self.growth_rate = growth_rate
        self.mutation_rate = mutation_rate

cdef class Deme:
    '''The neutral deme. Initiate selection deme or selection_mutation deme as appropriate.'''
# Assumes population in each deme is fixed!
# Otherwise random number generator breaks down.
# Include selection too

    cdef:
        readonly Individual[:] members
        readonly long num_alleles
        readonly long[:] binned_alleles
        readonly long num_individuals
        readonly double[:] growth_rate_list
        readonly double mutate_every # Time between each mutation
        readonly double cur_gen

    def __init__(Deme self,  long num_alleles, Individual[:] members not None):
        self.members = members
        self.num_individuals = len(members)
        self.num_alleles = num_alleles
        self.binned_alleles = self.bin_alleles()

        self.neighbors=None

        self.cur_gen = 0
        self.TIME_PER_ITERATION = 1./self.num_individuals

        # Initialize the growth rate array
        cdef Individual ind
        temp_growth_list = []
        for ind in self.members:
            temp_growth_list.append(ind.growth_rate)
        self.growth_rate_list = np.array(temp_growth_list, dtype = np.double)

        # Setup swapping parameters
        if self.frac_swap == 0:
            self.swap_every = -1.0
        else:
            self.swap_every = 1.0/(self.frac_swap * self.num_individuals)

    cdef reproduce_die_step(Deme self, gsl_rng *r):
        '''Time is scaled by reproduction steps. So do everything relative to that.'''

        cdef unsigned int to_reproduce = self.get_reproduce(r)
        cdef unsigned int to_die = self.get_die(r)

        # Update allele array

        cdef Individual individual_to_die =  self.members[to_die]
        cdef Individual individual_to_reproduce = self.members[to_reproduce]

        cdef int allele_to_die = individual_to_die.allele_id
        cdef int allele_to_reproduce = individual_to_reproduce.allele_id

        # Update the binned alleles
        self.binned_alleles[allele_to_die] -= 1
        self.binned_alleles[allele_to_reproduce] += 1
        # Update the growth rate array; take the small (hopefully) hit in speed
        # for the neutral case to get additional flexibility
        cdef double surviving_growth_rate = self.growth_rate_list[to_reproduce]
        self.growth_rate_list[to_die] = surviving_growth_rate

        # Update the members
        # This is a little silly, i.e. doing this in two steps, but
        # it doesn't seem to work otherwise
        cdef Individual reproducer = self.members[to_reproduce]
        self.members[to_die] = reproducer

        #### Deal with swapping ######
        cdef Deme d

        if self.swap_every != -1.0:

            if self.swap_every >= self.TIME_PER_ITERATION:
                for d in self.neighbors:
                    self.swap_members(d, r)


            if (self.cur_gen != 0) and (self.cur_gen % self.swap_every)
            # Only useful when you swap more than once per iteration
            cdef double num_times_to_swap = 1.0/swap_every

            cdef unsigned int i

            swap_count += 1 # So at the start of the loop this has a minimum of 1



            # Swap when appropriate
            if swap_every >= 2: # Swap less frequently than reproduction
                if swap_count >= swap_every:
                    swap_count = 0
                    num_times_swapped += 1
                    self.swap_with_neighbors(r)

            elif swap_every > 0: # Swap more frequently than reproduction
                while swap_count <= num_times_to_swap:
                    self.swap_with_neighbors(r)
                    swap_count += 1
                    num_times_swapped += 1

                #swap_count will always be too high as you just exited the for loop
                remainder += num_times_to_swap - (swap_count - 1)
                swap_count = 0
                if remainder >= 1:
                    remainder -= 1
                    self.swap_with_neighbors(r)
                    num_times_swapped += 1

        # Update the generation
        self.cur_gen += 1./self.num_individuals

    cdef unsigned long int get_reproduce(Deme self, gsl_rng *r):
        return gsl_rng_uniform_int(r, self.num_individuals)

    cdef unsigned long int get_die(Deme self, gsl_rng *r):
        return gsl_rng_uniform_int(r, self.num_individuals)

    cdef swap_members(Deme self, Deme other, gsl_rng *r):
        cdef:
            int i

            unsigned int self_swap_index = self.get_swap_index(r)
            unsigned int other_swap_index = other.get_swap_index(r)

            Individual self_swap
            Individual other_swap

        self_swap = self.members[self_swap_index]
        other_swap = other.members[other_swap_index]

        ## Update allele array of BOTH demes
        self.binned_alleles[self_swap.allele_id] -= 1
        self.binned_alleles[other_swap.allele_id] += 1

        other.binned_alleles[other_swap.allele_id] -= 1
        other.binned_alleles[self_swap.allele_id] += 1

        ## Update members
        self.members[self_swap_index] = other_swap
        other.members[other_swap_index] = self_swap

        cdef:
            other_fitness = other.growth_rate_list[other_swap_index]
            double self_fitness  = self.growth_rate_list[self_swap_index]

        self.growth_rate_list[self_swap_index] = other_fitness
        self.growth_rate_list[other_swap_index] = self_fitness

    cdef unsigned long int get_swap_index(Deme self, gsl_rng *r):
        return gsl_rng_uniform_int(r, self.num_individuals)

    cpdef get_alleles(Deme self):
        return [individual.allele_id for individual in self.members]

    cdef bin_alleles(Deme self):
        return np.bincount(self.get_alleles(), minlength=self.num_alleles)

    cpdef check_allele_frequency(Deme self):
        '''A diagnostic test that makes sure that the result returned by
        bin_alleles is the same as the current allele frequency. If it is false,
        there is a problem in the code somewhere.'''

        return np.array_equal(self.binned_alleles, self.bin_alleles())

cdef class Selection_Deme(Deme):

    # The only thing we have to update is the reproduce/die weighting function with selection
    cdef unsigned long int get_reproduce(Selection_Deme self, gsl_rng *r):
        '''We implement selection here. There is a higher chance to reproduce.'''
        cdef double rand_num = gsl_rng_uniform(r)

        cdef double cur_sum = 0
        cdef unsigned int index = 0

        # Normalize the fitnesses
        cdef double[:] normalized_weights = self.growth_rate_list / np.sum(self.growth_rate_list)

        cdef double normalized_sum = 0

        for index in range(self.num_individuals):
            cur_sum += normalized_weights[index]

            if cur_sum > rand_num:
                return index

        return -1

    # There is no increased probability to die in this model; don't have to adjust that

cdef class Ratchet_Deme(Deme):
    # We have to implement mutation now. Mutation occurs at a rate
    # different than birth/death, so we need to include something different.
    # Perhaps we should have the rate in generations...and do a mutation that often.
    cdef unsigned long int get_reproduce(Ratchet_Deme self, gsl_rng *r):
            '''We implement selection here. There is a higher chance to reproduce.'''
            cdef double rand_num = gsl_rng_uniform(r)

            cdef double cur_sum = 0
            cdef unsigned int index = 0

            # Normalize the fitnesses
            cdef double[:] normalized_weights = self.growth_rate_list / np.sum(self.growth_rate_list)

            cdef double normalized_sum = 0

            for index in range(self.num_individuals):
                cur_sum += normalized_weights[index]

                if cur_sum > rand_num:
                    return index

            return -1

    cdef reproduce_die_step(Ratchet_Deme self, gsl_rng *r):
        # Reproduce and die as usual.'''
        super(Ratchet_Deme, self).reproduce_die_step(r)
        # Now implement mutation; choose to do it depending on the fractional generation
        # cur_gen in a deme should have this information...right?


cdef class Simulate_Deme:
    cdef readonly Deme deme
    cdef readonly long num_generations
    cdef readonly unsigned long int seed

    cdef readonly long[:,:] history
    cdef readonly double[:] fractional_generation
    cdef readonly unsigned int num_iterations
    cdef readonly double record_every_fracgen
    cdef readonly unsigned int record_every
    cdef readonly double cur_gen

    def __init__(Simulate_Deme self, Deme deme, long num_generations,
                 unsigned long int seed = 0, double record_every_fracgen = -1.0):

        self.cur_gen = 0
        self.deme = deme
        self.num_generations = num_generations
        self.seed = seed
        self.record_every_fracgen = record_every_fracgen

        if self.record_every_fracgen == -1.0:
            self.record_every_fracgen = 1./self.deme.num_individuals

        # Calculate how many iterations you must wait before recording
        self.record_every = int(deme.num_individuals * self.record_every_fracgen)

        # The number of iterations is independent of how often we record
        self.num_iterations = (self.num_generations + 1) * self.deme.num_individuals
        # Take into account the zeroth state
        cdef int num_to_record = (self.num_iterations / self.record_every) + 1

        self.fractional_generation = -1*np.ones(num_to_record, dtype=np.double)
        self.history = -1*np.ones((num_to_record, deme.num_alleles), dtype=np.long)

    cpdef simulate(Simulate_Deme self):

        # Prepare random number generation
        np.random.seed(self.seed)

        cdef gsl_rng *r = gsl_rng_alloc(gsl_rng_mt19937)
        gsl_rng_set(r, self.seed)

        cdef unsigned long to_reproduce
        cdef unsigned long to_die
        cdef long i
        cdef long cur_num_individuals = self.deme.num_individuals
        cdef unsigned int count = 0

        cdef double generations_per_step = 1./self.deme.num_individuals

        for i in range(self.num_iterations):
            self.cur_gen = float(i)/self.deme.num_individuals
            if (i % self.record_every) == 0:
                self.fractional_generation[count] = self.cur_gen
                self.history[count, :] = self.deme.binned_alleles
                count += 1

            self.deme.reproduce_die_step(r)

        self.fractional_generation[count] = self.num_iterations/self.deme.num_individuals
        self.history[count, :] = self.deme.binned_alleles

        gsl_rng_free(r)

cdef class Simulate_Deme_Line:

    cdef readonly Deme[:] initial_deme_list
    cdef readonly Deme[:] deme_list
    cdef readonly long num_demes
    cdef readonly long num_individuals
    cdef readonly long num_alleles
    cdef readonly double fraction_swap

    cdef readonly long num_generations
    cdef readonly double record_every
    cdef readonly unsigned int num_iterations

    cdef readonly bool debug
    cdef readonly unsigned long int seed

    cdef readonly long[:,:,:] history
    cdef readonly double[:] frac_gen
    cdef readonly double cur_gen

    def __init__(Simulate_Deme_Line self, Deme[:] initial_deme_list, long num_alleles=2,
        long num_generations=100, double fraction_swap=0.1, double record_every = 1.0, unsigned long int seed=0,
        bool debug = False):
        '''  The user should input the list of demes. It is too annoying otherwise. There can be a utility
        function to generate common setups though.

        We assume m is the same for each deme, each deme has the same population,
        and that there is a known finite number of alleles at the start
        '''

        self.cur_gen = 0

        self.initial_deme_list = initial_deme_list.copy()
        self.deme_list = initial_deme_list

        self.num_individuals = initial_deme_list[0].num_individuals
        self.seed = seed

        #### Set the properties of the simulation ###

        self.num_demes = initial_deme_list.shape[0]

        self.num_alleles = num_alleles
        self.num_generations = num_generations
        self.record_every = record_every
        self.debug = debug

        cdef int num_records = int(self.num_generations / self.record_every) + 1

        self.frac_gen = np.empty(num_records)

        cdef double invalid_length

        if self.debug:
            invalid_length = np.sqrt(self.fraction_swap * self.num_individuals * self.num_generations)
            print 'Invalid length from walls is ~' , invalid_length

        self.num_iterations = self.num_generations * self.num_individuals + 1
        self.history = np.empty((num_records, self.num_demes, num_alleles), dtype=np.long)

        # Don't forget to link the demes!

        self.link_demes()

    def link_demes(Simulate_Deme_Line self):
        '''Set up the network structure; make sure not to double count!
        Create periodic or line BC's here, your choice'''

        cdef long i

        for i in range(self.num_demes):
            if i != (self.num_demes - 1):
                self.deme_list[i].neighbors = np.array([self.deme_list[i + 1]], dtype=Deme)
            else:
                self.deme_list[i].neighbors = np.array([self.deme_list[0]], dtype=Deme)

    cdef swap_with_neighbors(Simulate_Deme_Line self, gsl_rng *r):
        '''Be careful not to double swap! Each deme swaps once per edge.'''
        cdef long[:] swap_order
        cdef long swap_index
        cdef Deme current_deme
        cdef Deme[:] neighbors
        cdef Deme n

        # Create a permutation
        cdef int N = self.num_demes
        cdef gsl_permutation * p
        p = gsl_permutation_alloc (N)
        gsl_permutation_init (p)
        gsl_ran_shuffle(r, p.data, N, sizeof(size_t))

        cdef size_t *p_data = gsl_permutation_data(p)

        # Swap between all the neighbors once choosing the order randomly
        cdef int i
        cdef int j

        cdef int self_swap_index, other_swap_index
        cdef Deme otherDeme
        cdef int num_neighbors

        cdef int current_perm_index

        for i in range(N):
            current_perm_index = p_data[i]
            current_deme = self.deme_list[current_perm_index]
            neighbors = current_deme.neighbors
            num_neighbors = neighbors.shape[0]
            for j in range(num_neighbors):
                otherDeme = neighbors[j]
                current_deme.swap_members(otherDeme, r)

        gsl_permutation_free(p)

    cdef reproduce_line(Simulate_Deme_Line self, gsl_rng *r):
        cdef int d_num
        cdef long[:] current_alleles
        cdef Deme tempDeme

        cdef unsigned long int to_reproduce, to_die

        for d_num in range(self.num_demes):
            tempDeme = self.deme_list[d_num]
            tempDeme.reproduce_die_step(r)

    cpdef simulate(self):

        cdef double swap_every
        if self.fraction_swap == 0:
            swap_every = -1.0
        else:
            swap_every = 1.0/self.fraction_swap

        cdef long swap_count = 0
        cdef long num_times_swapped = 0
        cdef double remainder = 0

        # Only useful when you swap more than once per iteration
        cdef double num_times_to_swap = 1.0/swap_every

        # Use fast random number generation in mission critical methods
        # Make sure to delete this at the end to avoid memory leaks...
        cdef gsl_rng *r = gsl_rng_alloc(gsl_rng_mt19937)

        # Now set seeds
        np.random.seed(self.seed)
        gsl_rng_set(r, self.seed)

        # Figure out how many iterations you should go before recording
        cdef int record_every_iter = int(self.record_every * self.num_individuals)

        cdef int num_times_recorded = 0

        cdef unsigned int i

        for i in range(self.num_iterations):
            # Bookkeeping
            swap_count += 1 # So at the start of the loop this has a minimum of 1
            self.cur_gen = float(i)/self.num_individuals

            # Record every "record_every"
            if (i % record_every_iter == 0) or (i == (self.num_iterations - 1)):
                self.frac_gen[num_times_recorded] = self.cur_gen
                for d_num in range(self.num_demes):
                    self.history[num_times_recorded, d_num, :] = self.deme_list[d_num].binned_alleles
                num_times_recorded += 1

            # Reproduce
            self.reproduce_line(r)

            # Swap when appropriate
            if swap_every >= 2: # Swap less frequently than reproduction
                if swap_count >= swap_every:
                    swap_count = 0
                    num_times_swapped += 1
                    self.swap_with_neighbors(r)

            elif swap_every > 0: # Swap more frequently than reproduction
                while swap_count <= num_times_to_swap:
                    self.swap_with_neighbors(r)
                    swap_count += 1
                    num_times_swapped += 1

                #swap_count will always be too high as you just exited the for loop
                remainder += num_times_to_swap - (swap_count - 1)
                swap_count = 0
                if remainder >= 1:
                    remainder -= 1
                    self.swap_with_neighbors(r)
                    num_times_swapped += 1

        # Check that gene frequencies are correct!

        cdef long num_correct = 0
        if self.debug:
            for d in self.deme_list:
                if d.check_allele_frequency():
                    num_correct += 1
                else:
                    print 'Incorrect allele frequencies!'
            print 'Num correct:' , num_correct, 'out of', len(self.deme_list)

            # Check number of times swapped
            print 'Fraction swapped:' , num_times_swapped / float(self.num_generations*self.num_individuals)
            print 'Desired fraction:' , self.fraction_swap

        # DONE! Deallocate as necessary.
        gsl_rng_free(r)

    ####### Utility Classes #######

    def count_sectors(Simulate_Deme_Line self, double cutoff = 0.1):
        '''Run this after the simulation has concluded to count the number of sectors'''
        # All you have to do is to count what the current domain type is and when it changes.
        # This is complicated by the fact that everything is fuzzy and that there can be
        # multiple colors.
        cdef int i

        data_list = []

        for i in range(self.deme_list.shape[0]):

            current_alleles = np.asarray(self.deme_list[i].binned_alleles)
            allele_frac = current_alleles / self.num_individuals
            dominant_sectors = allele_frac > cutoff

            data_list.append(dominant_sectors)

        return np.array(data_list)

    cpdef F_ij(Simulate_Deme_Line self, long i, long j, x1):

        m = self.position_map
        start_deme_index = m[m['position'] == x1].index[0]

        delta_positions = self.position_map.copy()

        delta_positions['position'] -= x1

        # Now calculate the heterozygosity at each time for each deme which have a
        # given position
        fij = np.empty((self.num_generations, self.num_demes))

        frac_history = np.asarray(self.history)/float(self.num_individuals)

        for gen_index in range(self.num_generations):
            fij[gen_index, :] = frac_history[gen_index, start_deme_index, i] * frac_history[gen_index, :, j]

        return fij, delta_positions

    def animate(Simulate_Deme_Line self, generation_spacing = 1, interval = 1):
        '''Animates at the desired generation spacing using matplotlib'''
        history = np.asarray(self.history)
        # Only get data for every generation
        history_pieces = history[:, ::self.num_individuals, :]

        # Set up canvas to be plotted
        fig = plt.figure()
        ax = plt.axes(xlim = (0, self.num_demes), ylim = (0, 1))
        line, = ax.plot([], [])

        # Begin plotting

        x_values = np.arange(self.num_demes)
        fractional_pieces = history_pieces / float(self.num_individuals)

        num_frames = self.num_generations / generation_spacing

        def init():
            line.set_data(x_values, fractional_pieces[:, 0, 0])
            return line,

        def animate_frame(i):
            line.set_data(x_values, fractional_pieces[:, generation_spacing * i, 0])
            return line,

        return animation.FuncAnimation(fig, animate_frame, blit=True, init_func = init,
                                       frames=num_frames, interval=interval)

    def get_allele_history(Simulate_Deme_Line self, long allele_num):

        history = np.asarray(self.history)
        fractional_history = history/float(self.num_individuals)

        num_entries = len(self.frac_gen)

        pixels = np.empty((num_entries, self.num_demes))

        cdef int i

        for i in range(num_entries):
            pixels[i, :] = fractional_history[i, :, allele_num]

        return pixels

    def get_color_array(Simulate_Deme_Line self):

        cmap = plt.get_cmap('gist_rainbow')
        cmap.N = self.num_alleles

        # Hue will not be taken into account
        color_array = cmap(np.linspace(0, 1, self.num_alleles))

        alleleList = []
        for i in range(self.num_alleles):
            alleleList.append(self.get_allele_history(i))

        image = np.zeros((alleleList[0].shape[0], alleleList[0].shape[1], 4))

        for i in range(self.num_alleles):
            currentAllele = alleleList[i]

            redArray = currentAllele * color_array[i, 0]
            greenArray = currentAllele * color_array[i, 1]
            blueArray = currentAllele * color_array[i, 2]
            aArray = currentAllele * color_array[i, 3]

            image[:, :, 0] += redArray
            image[:, :, 1] += greenArray
            image[:, :, 2] += blueArray
            image[:, :, 3] += aArray

        #There is likely a faster way to do this involving the history, and multiplying it by cmap or something

        return image

    def get_color_array_by_fitness(Simulate_Deme_Line self):
        # We just have to cycle through the history and calculate the average selective advantage
        # at each point. I might have to do this as we go, however...
        print 'Not done yet'
        #TODO Make these plots looking at fitness instead of allele. It is a more robust measure of what is going on.
