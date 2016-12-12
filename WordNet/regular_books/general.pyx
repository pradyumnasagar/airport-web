cimport cython
from itertools import combinations, tee
import numpy as np
cimport numpy as np
from itertools import chain
from collections import Counter
from os import path as ospath
from operator import itemgetter
import json
import glob
# from mylib cimport maximum, max_iter
# DTYPE = np.object
# ctypedef np.object_t DTYPE_t

cdef int iteration_number = 4
cdef dict s_include_word
cdef dict sentence_with_indices
cdef dict word_with_indices
counter = {}
cdef int sum5
cdef np.ndarray all_sent
cdef np.ndarray all_words
cdef dict main_dict
cdef dict w_w_i
cdef dict s_w_i
cdef np.ndarray latest_SSM_numpy
cdef np.ndarray latest_WSM_numpy
cdef dict all_weights = {}

cdef tuple initial(main_dict):
    main_dict = {i: set(j) for i, j in main_dict.items() if j}
    cdef np.ndarray all_sent = np.array(list(main_dict))
    cdef np.ndarray all_words = np.unique(np.fromiter(chain.from_iterable(main_dict.values()),
                                          dtype='U20'))
    return all_words, all_sent, main_dict

cdef dict create_words_with_indices():
    cdef dict total = {}
    for s, words in main_dict.items():
        if len(words) > 1:
            total[s] = itemgetter(*words)(w_w_i)
        elif words:
            total[s] = (w_w_i[next(iter(words))], )
    return total

cdef dict create_sentence_with_indices(s_include_word):
    cdef dict total = {}
    for w in all_words:
        sentences = s_include_word[w]
        if len(sentences) > 1:
            total[w] = itemgetter(*sentences)(s_w_i)
        elif sentences:
            total[w] = (s_w_i[sentences.pop()], )
    return total

cdef set sentence_include_word(word):
    return {sent for sent, words in main_dict.items() if word in words}

cdef float weight(str S, str W):
    cdef float word_factor = max(0, 1 - counter[W] / sum5)
    cdef float other_words_factor = sum(max(0, 1 - counter[w] / sum5) for w in main_dict[S])
    return word_factor / other_words_factor

cdef dict cal_weights():
    cdef dict cache_weights = {}
    for w, sentences in s_include_word.items():
        for s in sentences:
            s, w = str(s), str(w)
            cache_weights[(s, w)] = weight(s, w)
    for s, words in main_dict.items():
        for w in words:
            s, w = str(s), str(w)
            if (s, w) not in cache_weights:
                cache_weights[(s, w)] = weight(s, w)
    return cache_weights

cdef void run():
    global all_words
    global all_sent
    global s_include_word
    global sentence_with_indices
    global word_with_indices
    global counter
    global sum5
    global main_dict
    global latest_WSM
    global latest_SSM
    global w_w_i
    global s_w_i
    global all_weights

    file_names = glob.glob("files/*.json")
    for name in file_names[1::2]:
        with open(name) as f:
            print(name)
            d = json.load(f)
            # d = dict(list(d.items())[:1000])
        all_words, all_sent, main_dict = initial(d)
        print("All words {}".format(len(all_words)))
        w_w_i = {w: i for i, w in enumerate(all_words)}
        s_w_i = {s: i for i, s in enumerate(all_sent)}
        latest_SSM = create_SSM()
        latest_WSM = create_WSM()
        s_include_word = {w: sentence_include_word(w) for w in all_words}
        sentence_with_indices = create_sentence_with_indices(s_include_word)
        word_with_indices = create_words_with_indices()
        counter = Counter(all_words)
        sum5 = sum(j for _, j in counter.most_common(5))
        all_weights = cal_weights()
        iteration(name.split('/')[1].split('.')[0], latest_SSM, latest_WSM)
        names = ['all_words',
                 'all_sent',
                 's_include_word',
                 'sentence_with_indices',
                 'word_with_indices',
                 'counter',
                 'sum5',
                 'main_dict',
                 'latest_WSM',
                 'latest_SSM',
                 'w_w_i',
                 's_w_i',
                 'latest_SSM_numpy',
                 'latest_WSM_numpy',
                 'all_weights']
        for nam in names:
            globals().update({name: None})


def create_SSM():
    """
    Initialize the sentence similarity matrix by creating a NxN zero filled
    matrix where N is the number of sentences.
    """
    cdef int size = all_sent.size
    # dt = np.dtype({"names": all_sent,
    #               "formats": [np.float32] * size})
    cdef np.float32_t[:, :] ssm = np.zeros((size, size), dtype=np.float32)
    return ssm


def create_WSM():
    """
    Initialize the word similarity matrix by creating a matrix with
    1 as its main digonal and columns with word names.
    """
    cdef int size = all_words.size
    # dt = np.dtype({"names": all_words, "formats": [np.float32] * all_words.size})
    arr = np.zeros((size, size), dtype=np.float32)
    # wsm_view = wsm.view(np.float32).reshape(size, -1)
    np.fill_diagonal(arr, 1)
    cdef np.float32_t[:, :] wsm = arr
    return wsm

cdef float affinity_WS(str W, str S, np.float32_t[:, :] latest_WSM):
    cdef float result=0, max_val=0
    cdef tuple wwi = word_with_indices[S]
    cdef int i, wwiw = w_w_i[W]
    for i in wwi:
        max_val = latest_WSM[wwiw, i]
        if max_val > result:
            result = max_val
        return result

cdef float affinity_SW(str S, str W, np.float32_t[:, :] latest_SSM):
    cdef float result=0, max_val=0
    cdef tuple swi = sentence_with_indices[W]
    cdef int i, swis = s_w_i[S]
    for i in swi:
        max_val = latest_SSM[swis, i]
        if max_val > result:
            result = max_val
        return result

cdef float similarity_W(str W1, str W2, np.float32_t[:, :] latest_SSM):
    cdef float aff=0, summ=0, weight_vali=0
    cdef set siw = s_include_word[W1]
    for s in siw:
        aff = affinity_SW(s, W2, latest_SSM)
        weight_val = all_weights[(s, W1)]
        summ = summ + weight_val * aff
    return summ

cdef float similarity_S(str S1, str S2, np.float32_t[:, :] latest_WSM):
    cdef float aff=0, summ=0, weight_vali=0
    cdef set words = main_dict[S1]
    for w in words:
        weight_val = all_weights[(S1, w)]
        aff = affinity_WS(w, S2, latest_WSM)
        summ = summ + weight_val * aff
    return summ

cdef void save_matrixs(name):
    np.save("sentences_{}.txt".format(name), all_sent)
    np.save("SSM_{}.txt".format(name), latest_SSM)
    np.save("words_{}.txt".format(name), all_words)
    np.save("WSM_{}.txt".format(name), latest_WSM)


@cython.boundscheck(False)
@cython.wraparound(False)
cdef void iteration(name, np.float32_t[:, :] latest_SSM, np.float32_t[:, :] latest_WSM):
    sent_comb = combinations(map(str, all_sent), 2)
    word_comb = combinations(map(str, all_words), 2)
    sent_comb = iter(tee(sent_comb, 4))
    word_comb = iter(tee(word_comb, 4))
    cdef int w_size = all_words.size
    cdef int s_size = all_sent.size
    cdef np.ndarray ind_uper_s = np.column_stack(np.triu_indices(s_size, 1))
    cdef np.ndarray ind_uper_w = np.column_stack(np.triu_indices(w_size, 1))
    cdef int x, y, k, t
    cdef float val
    cdef str s1, s2, w1, w2
    for i in range(iteration_number):
        # Update SSM
        t = 0
        for s1, s2 in next(sent_comb):
            val = similarity_S(s1, s2, latest_WSM)
            x, y = ind_uper_s[t][0], ind_uper_s[t][1]
            latest_SSM[x, y] = val
            latest_SSM[y, x] = val
            t = t + 1
        print("Finished similarity_S, iteration {}".format(i + 1))
        # Update WSM
        k = 0
        for w1, w2 in next(word_comb):
            val = similarity_W(w1, w2, latest_SSM)
            x, y = ind_uper_w[k][0], ind_uper_w[k][1]
            latest_WSM[x, y] = val
            latest_WSM[y, x] = val
            k = k + 1
        print("Finished similarity_W, iteration {}".format(i + 1))

    save_matrixs(name)


def main():
    run()
