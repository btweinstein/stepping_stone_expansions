__author__ = 'bryan'

import numpy as np
import range_expansions as re
import ternary

def simulate_deme_many_times(initial_condition, num_alleles, num_generations, num_times, record_every_fracgen):

    number_of_records = int(num_generations / record_every_fracgen + 1)

    sim_list = np.empty((num_times, number_of_records, num_alleles))

    num_individuals = len(initial_condition)

    frac_gen = None

    for i in range(num_times):
        # Set the seed
        seed = np.random.randint(0, 2**32 -1)
        # Set half of the individuals to 0 and the other half to 1, fo=0.5

        ind_list = np.array([re.Individual(j) for j in initial_condition])
        deme = re.Deme(num_alleles, ind_list)

        frac_gen, history = re.simulate_deme(deme, num_generations, seed, record_every_fracgen)
        frac_gen = np.asarray(frac_gen)
        history = np.asarray(history)
        frac_history = history/float(num_individuals)

        sim_list[i, :, :] = frac_history

    sim_list = np.asarray(sim_list)
    frac_gen = np.asarray(frac_gen)

    return sim_list, frac_gen

class Simulate_3_Alleles_Deme:
    '''A convenience class to do 3 color stepping stone models. Also
        cotains methods to plot the results on a triangle.'''

    def __init__(self, initial_condition, num_generations, num_simulations, record_every=None):
        self.num_alleles = 3
        self.initial_condition = initial_condition
        self.num_individuals = initial_condition.shape[0]
        self.num_generations = num_generations
        self.num_simulations = num_simulations

        self.record_every = record_every
        if self.record_every is None:
            self.record_every = 1./(initial_condition.shape[0])

        # Does the simulation

        self.sim_list, self.frac_gen = simulate_deme_many_times(self.initial_condition, self.num_alleles,
                                                                self.num_generations, self.num_simulations,
                                                                self.record_every)

        # Collects the data in a convenient way
        self.edges, self.centers = self.get_hist_edges_and_center()
        self.histogrammed_data = self.get_2d_histogram_in_time()

        self.x_center_mesh, self.y_center_mesh = np.meshgrid(self.centers, self.centers)
        self.x_rav = self.x_center_mesh.ravel()
        self.y_rav = self.y_center_mesh.ravel()


    def get_hist_edges_and_center(self):
        edges = np.arange(-1./(2*self.num_individuals), 1 + 2 *(1./(2*self.num_individuals)),
                          1./self.num_individuals)
        centers = (edges[:-1] + edges[1:])/2.

        return edges, centers

    def get_2d_histogram_in_time(self):
        num_bins = self.centers.shape[0]
        num_records = self.frac_gen.shape[0]
        histogrammed_data = np.empty((num_records, num_bins, num_bins))

        for i in range(num_records):
            histogrammed_data[i, :, :] = np.histogram2d(self.sim_list[:, i, 0], self.sim_list[:, i, 1], self.edges)[0]
            histogrammed_data[i, :, :] /= float(self.num_simulations)
        return histogrammed_data

    def get_histdict_for_iteration(self, i):
        hist_rav = self.histogrammed_data[i, :, :].ravel()
        return dict([((x,y),z) for x,y,z in zip(self.x_rav, self.y_rav, hist_rav)])