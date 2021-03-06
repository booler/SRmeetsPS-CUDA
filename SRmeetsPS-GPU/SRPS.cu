#include "SRPS.h"

SRPS::SRPS(DataHandler& dh) {
	this->dh = &dh;
}

SRPS::~SRPS() {}

template <typename T>
void set_sparse_matrix_for_gradient(SparseCOO<T>& D, thrust::host_vector<int>& ic, thrust::host_vector<int>& ir, float k1, float k2) {
	memcpy(D.row, ic.data(), sizeof(int)*ic.size());
	memcpy(D.row + ic.size(), ic.data(), sizeof(int)*ic.size());
	memcpy(D.col, ir.data(), sizeof(int)*ir.size());
	memcpy(D.col + ir.size(), ic.data(), sizeof(int)*ic.size());
	for (size_t i = 0; i < ic.size(); i++) {
		D.val[i] = k1;
	}
	for (size_t i = ic.size(); i < 2 * ic.size(); i++) {
		D.val[i] = k2;
	}
}

std::pair<SparseCOO<float>, SparseCOO<float>> make_gradient(float* mask, int h, int w, int* index_in_masked_matrix, int mask_size) {
	thrust::host_vector<int> ic_top, ir_top;
	thrust::host_vector<int> ic_left, ir_left;
	thrust::host_vector<int> ic_right, ir_right;
	thrust::host_vector<int> ic_bottom, ir_bottom;

	for (int j = 0; j < w; j++) {
		for (int i = 0; i < h; i++) {
			if (i + 1 < h && mask[i + j * h] != 0 && mask[i + 1 + j * h] != 0) {
				ic_bottom.push_back(index_in_masked_matrix[i + j * h]);
				ir_bottom.push_back(index_in_masked_matrix[i + 1 + j * h]);
			}
			else if (i - 1 >= 0 && mask[i + j * h] != 0 && mask[i - 1 + j * h] != 0) {
				ic_top.push_back(index_in_masked_matrix[i + j * h]);
				ir_top.push_back(index_in_masked_matrix[i - 1 + j * h]);
			}
			if (j + 1 < w && mask[i + j * h] != 0 && mask[i + (j + 1) * h] != 0) {
				ic_right.push_back(index_in_masked_matrix[i + j * h]);
				ir_right.push_back(index_in_masked_matrix[i + (j + 1) * h]);
			}
			else if (j - 1 >= 0 && mask[i + j * h] != 0 && mask[i + (j - 1) * h] != 0) {
				ic_left.push_back(index_in_masked_matrix[i + j * h]);
				ir_left.push_back(index_in_masked_matrix[i + (j - 1) * h]);
			}
		}
	}

	SparseCOO<float> Dxp(mask_size, mask_size, (int)ic_right.size() * 2);
	set_sparse_matrix_for_gradient<float>(Dxp, ic_right, ir_right, 1, -1);

	SparseCOO<float> Dxn(mask_size, mask_size, (int)ic_left.size() * 2);
	set_sparse_matrix_for_gradient<float>(Dxn, ic_left, ir_left, -1, 1);

	SparseCOO<float> Dyp(mask_size, mask_size, (int)ic_bottom.size() * 2);
	set_sparse_matrix_for_gradient<float>(Dyp, ic_bottom, ir_bottom, 1, -1);

	SparseCOO<float> Dyn(mask_size, mask_size, (int)ic_top.size() * 2);
	set_sparse_matrix_for_gradient<float>(Dyn, ic_top, ir_top, -1, 1);

	SparseCOO<float> Dx = Dxp + Dxn;
	SparseCOO<float> Dy = Dyp + Dyn;

	Dxp.freeMemory();
	Dyp.freeMemory();
	Dxn.freeMemory();
	Dyn.freeMemory();

	return  std::pair<SparseCOO<float>, SparseCOO<float>>(Dx, Dy);
}

template<class Iter, class T>
Iter binary_find(Iter begin, Iter end, T val)
{
	// Finds the lower bound in at most log(last - first) + 1 comparisons
	Iter i = std::lower_bound(begin, end, val);
	if (i != end && !(val < *i))
		return i; // found
	else
		return end; // not found
}

void SRPS::execute() {
	float TOLERANCE = 5e-3f;
	int MAX_ITERATIONS = 10;
	
	cudaSetDevice(Preferences::deviceId);

	// Initialize CUBLAS/CUSPARSE
	cusparseHandle_t cusp_handle = 0;
	cublasHandle_t cublas_handle = 0;
	if (cusparseCreate(&cusp_handle) != CUSPARSE_STATUS_SUCCESS) {
		throw std::runtime_error("CUSPARSE Library initialization failed");
	}
	if (cublasCreate(&cublas_handle) != CUBLAS_STATUS_SUCCESS) {
		throw std::runtime_error("CUBLAS Library initialization failed");
	}

	// Move downsampling Matrix to device in CSR format
	int* d_D_row_ptr, *d_D_col_ind;
	float* d_D_val;
	cuda_based_host_COO_to_device_CSR(cusp_handle, &dh->D, &d_D_row_ptr, &d_D_col_ind, &d_D_val);

	// Create mask for the downsampled image (GPU)
	std::cout << "Small mask calculation" << std::endl;
	float* d_mask = NULL;
	cudaMalloc(&d_mask, sizeof(float) * dh->I_h * dh->I_w);
	cudaMemcpy(d_mask, dh->mask, sizeof(float) * dh->I_h * dh->I_w, cudaMemcpyHostToDevice);
	float* d_masks = cuda_based_sparsemat_densevec_mul(cusp_handle, d_D_row_ptr, d_D_col_ind, d_D_val, dh->D.n_row, dh->D.n_col, dh->D.n_nz, d_mask);
	thrust::replace_if(THRUST_CAST(d_masks), THRUST_CAST(d_masks) + dh->D.n_row, is_less_than_one(), 0.f);
	
	// Copy it back to host for imasks calculation 
	float* masks = new float[dh->D.n_row];
	cudaMemcpy(masks, d_masks, sizeof(float)*dh->D.n_row, cudaMemcpyDeviceToHost); CUDA_CHECK;
	
	// Depth mean (GPU), inpainting (CPU) and smoothing (CPU)
	
	std::cout << "Mean of depth values" << std::endl;
	float* inpaint_mask = new float[dh->z0_h*dh->z0_w];
	float* zs = new float[dh->z0_h*dh->z0_w];
	uint8_t* inpaint_locations = new uint8_t[dh->z0_h*dh->z0_w];
	uint8_t* d_inpaint_locations = NULL;
	float* d_zs = cuda_based_mean_across_channels(dh->z0, dh->z0_h, dh->z0_w, dh->z0_n, &d_inpaint_locations);
	cudaMemcpy(zs, d_zs, sizeof(float)*dh->z0_h*dh->z0_w, cudaMemcpyDeviceToHost); CUDA_CHECK;
	cudaMemcpy(inpaint_locations, d_inpaint_locations, sizeof(uint8_t)*dh->z0_h*dh->z0_w, cudaMemcpyDeviceToHost); CUDA_CHECK;
	cudaFree(d_inpaint_locations); CUDA_CHECK;
	
	std::cout << "Inpainting depth values" << std::endl;
	cv::Mat zs_mat((int)dh->z0_w, (int)dh->z0_h, CV_32FC1, zs);
	cv::Mat zs_out_mat((int)dh->z0_w, (int)dh->z0_h, CV_32FC1);
	cv::Mat inpaint_locations_mat((int)dh->z0_w, (int)dh->z0_h, CV_8UC1, inpaint_locations);
	cv::inpaint(zs_mat, inpaint_locations_mat, zs_mat, 16, cv::INPAINT_TELEA);
	
	std::cout << "Smoothing depth" << std::endl;
	double min, max;
	cv::minMaxIdx(zs_mat, &min, &max);
	zs_mat = zs_mat / max;
	cv::bilateralFilter(zs_mat, zs_out_mat, -1, 2, 2);
	zs_out_mat *= max;
	cudaMemcpy(d_zs, zs_out_mat.data, sizeof(float)*dh->z0_h*dh->z0_w, cudaMemcpyHostToDevice); CUDA_CHECK;
	
	WRITE_MAT_FROM_DEVICE(d_zs, dh->z0_h*dh->z0_w, "zs_init.mat");
	
	// Upscale of depth to get initial estimate of z (CPU) 
	std::cout << "Resample depths" << std::endl;
	float* z_full = new float[dh->I_h*dh->I_w];
	cv::Mat z_mat((int)dh->I_w, (int)dh->I_h, CV_32FC1, z_full);
	cv::resize(zs_out_mat, z_mat, cv::Size(dh->I_h, dh->I_w), 0, 0, cv::INTER_CUBIC);

	// Indices of Mask and Masks (CPU)
	std::cout << "Mask index calculation" << std::endl;
	thrust::host_vector<int> imask, imasks;
	int* index_in_masked_matrix = new int[dh->I_h*dh->I_w];
	memset(index_in_masked_matrix, 0, sizeof(int)*dh->I_h*dh->I_w);
	int ctr = 0;
	for (int i = 0; i < dh->D.n_col; i++) {
		if (dh->mask[i] != 0) {
			imask.push_back(i);
			index_in_masked_matrix[i] = ctr++;
		}
	}
	for (int i = 0; i < dh->D.n_row; i++) {
		if (masks[i] != 0)
			imasks.push_back(i);
	}
	int npix = (int)imask.size();
	int npixs = (int)imasks.size();

	// Calculation of filtered resample matrix that operates only on the masked pixels (CPU)
	std::cout << "Masked resample matrix" << std::endl;
	thrust::host_vector<int> KT_row;
	thrust::host_vector<int> KT_col;
	thrust::sort(thrust::host, imask.begin(), imask.end());
	thrust::sort(thrust::host, imasks.begin(), imasks.end());
	for (int i = 0; i < dh->D.n_nz; i++) {
		thrust::detail::normal_iterator<int*> its = binary_find(imasks.begin(), imasks.end(), dh->D.row[i]);
		thrust::detail::normal_iterator<int*> it = binary_find(imask.begin(), imask.end(), dh->D.col[i]);
		if (its != imasks.end() && it != imask.end()) {
			KT_row.push_back(its - imasks.begin());
			KT_col.push_back(it - imask.begin());
		}
	}
	SparseCOO<float> KT((int)imasks.size(), (int)imask.size(), (int)KT_row.size());
	memcpy(KT.row, KT_row.data(), KT_row.size() * sizeof(int));
	memcpy(KT.col, KT_col.data(), KT_col.size() * sizeof(int));
	for (size_t i = 0; i < KT_row.size(); i++) {
		KT.val[i] = 1.f / (dh->sf*dh->sf);
	}
	int* d_KT_row_ptr, *d_KT_col_ind;
	float* d_KT_val;
	cuda_based_host_COO_to_device_CSR(cusp_handle, &KT, &d_KT_row_ptr, &d_KT_col_ind, &d_KT_val);
	KT.freeMemory();

	// Create gradient matrices for non square shapes (CPU)
	std::cout << "Masked gradient matrix" << std::endl;
	std::pair<SparseCOO<float>, SparseCOO<float>> G = make_gradient(dh->mask, dh->I_h, dh->I_w, index_in_masked_matrix, (int)imask.size());
	int* d_Dx_row_ptr, *d_Dx_col_ind, *d_Dy_row_ptr, *d_Dy_col_ind;
	float* d_Dx_val, *d_Dy_val;
	cuda_based_host_COO_to_device_CSR(cusp_handle, &G.first, &d_Dx_row_ptr, &d_Dx_col_ind, &d_Dx_val);
	cuda_based_host_COO_to_device_CSR(cusp_handle, &G.second, &d_Dy_row_ptr, &d_Dy_col_ind, &d_Dy_val);
	G.first.freeMemory();
	G.second.freeMemory();


	std::cout << "Initialization" << std::endl;

	// Lighting (s) initialization (GPU)
	float* d_s = NULL;
	cudaMalloc(&d_s, dh->I_n * dh->I_c * 4 * sizeof(float)); CUDA_CHECK;
	cudaMemset(d_s, 0, dh->I_c * 4 * dh->I_n * sizeof(float)); CUDA_CHECK;
	thrust::device_ptr<float> dt_s = thrust::device_pointer_cast(d_s);
	for (int i = 0; i < dh->I_n; i++) {
		for (int j = 0; j < dh->I_c; j++) {
			dt_s[i * 4 * dh->I_c + j * 4 + 2] = -1;
		}
	}

	// Albedo (rho) initialization (GPU) 
	float* d_rho = cuda_based_rho_init(imask, dh->I_c);

	// Copying masked portion of I (GPU)
	float* d_I = NULL, *d_I_complete = NULL, *d_mask_extended = NULL;
	cudaMalloc(&d_I, imask.size() * dh->I_c * dh->I_n * sizeof(float)); CUDA_CHECK;
	cudaMalloc(&d_I_complete, dh->I_w * dh->I_h * dh->I_c * sizeof(float)); CUDA_CHECK;
	cudaMalloc(&d_mask_extended, dh->I_w * dh->I_h * dh->I_c * sizeof(float)); CUDA_CHECK;
	for (int n = 0; n < dh->I_n; n++) {
		for (int i = 0; i < dh->I_c; i++)
			cudaMemcpy(d_mask_extended + dh->I_w * dh->I_h * i, d_mask, dh->I_w * dh->I_h * sizeof(float), cudaMemcpyDeviceToDevice); CUDA_CHECK;
		cudaMemcpy(d_I_complete, dh->I + n * dh->I_w * dh->I_h * dh->I_c, dh->I_w * dh->I_h * dh->I_c * sizeof(float), cudaMemcpyHostToDevice); CUDA_CHECK;
		thrust::copy_if(thrust::device, THRUST_CAST(d_I_complete), THRUST_CAST(d_I_complete) + dh->I_c*dh->I_w*dh->I_h, THRUST_CAST(d_mask_extended), THRUST_CAST(d_I) + imask.size() * dh->I_c * n, is_one()); CUDA_CHECK;
	}
	cudaFree(d_mask_extended); CUDA_CHECK;
	cudaFree(d_I_complete); CUDA_CHECK;
	
	// Copying masked portion of LR depth (GPU)
	float *d_z0s = NULL;
	cudaMalloc(&d_z0s, sizeof(float)*imasks.size()); CUDA_CHECK;;
	thrust::copy_if(thrust::device, THRUST_CAST(d_zs), THRUST_CAST(d_zs) + dh->z0_h*dh->z0_w, THRUST_CAST(d_masks), THRUST_CAST(d_z0s), is_one()); CUDA_CHECK;

	// Copying masked portion of initial HR depth (GPU)
	float* d_z = NULL, *d_z_full = NULL;
	cudaMalloc(&d_z, sizeof(float)*imask.size()); CUDA_CHECK;
	cudaMalloc(&d_z_full, sizeof(float)*dh->I_h*dh->I_w); CUDA_CHECK;
	cudaMemcpy(d_z_full, z_full, sizeof(float)*dh->I_h*dh->I_w, cudaMemcpyHostToDevice); CUDA_CHECK;
	thrust::copy_if(thrust::device, THRUST_CAST(d_z_full), THRUST_CAST(d_z_full) + dh->I_w*dh->I_h, THRUST_CAST(d_mask), THRUST_CAST(d_z), is_one()); CUDA_CHECK;
	cudaFree(d_z_full);
	cudaFree(d_zs); CUDA_CHECK;
	
	WRITE_MAT_FROM_DEVICE(d_z, imask.size(), "z_init.mat");
	
	// Meshgrid for normal estimation (GPU)
	float* d_xx = NULL, *d_yy = NULL;
	cudaMalloc(&d_xx, sizeof(float)*imask.size()); CUDA_CHECK;
	cudaMalloc(&d_yy, sizeof(float)*imask.size()); CUDA_CHECK;
	std::pair<float*, float*> d_meshgrid = cuda_based_meshgrid_create(dh->I_w, dh->I_h, dh->K[6], dh->K[7]);
	thrust::copy_if(thrust::device, THRUST_CAST(d_meshgrid.first), THRUST_CAST(d_meshgrid.first) + dh->I_w*dh->I_h, THRUST_CAST(d_mask), THRUST_CAST(d_xx), is_one()); CUDA_CHECK;
	thrust::copy_if(thrust::device, THRUST_CAST(d_meshgrid.second), THRUST_CAST(d_meshgrid.second) + dh->I_w*dh->I_h, THRUST_CAST(d_mask), THRUST_CAST(d_yy), is_one()); CUDA_CHECK;
	cudaFree(d_meshgrid.first);
	cudaFree(d_meshgrid.second);

	// zx and zy for normal estimation (GPU)
	float *d_zx = NULL, *d_zy = NULL;
	d_zx = cuda_based_sparsemat_densevec_mul(cusp_handle, d_Dx_row_ptr, d_Dx_col_ind, d_Dx_val, G.first.n_row, G.first.n_col, G.first.n_nz, d_z);
	d_zy = cuda_based_sparsemat_densevec_mul(cusp_handle, d_Dy_row_ptr, d_Dy_col_ind, d_Dy_val, G.second.n_row, G.second.n_col, G.second.n_nz, d_z);
	
	// Normal initialization (GPU)
	float* d_dz = NULL;
	float* d_N = cuda_based_normal_init(cublas_handle, d_z, d_zx, d_zy, d_xx, d_yy, (int)imask.size(), dh->K[0], dh->K[4], &d_dz);
	float* d_init_N = cuda_based_normal_init(cublas_handle, d_z, d_zx, d_zy, d_xx, d_yy, (int)imask.size(), dh->K[0], dh->K[4], &d_dz);
	
	// Core algorithm (GPU)
	float last_error = NAN;
	bool stop_loop = false;
	int iteration = 1;
	do {
		Timer timer;
		
		timer.start();
		// Lighting estimation (GPU)
		cuda_based_lightning_estimation(cublas_handle, cusp_handle, d_s, d_rho, d_N, d_I, (int)imask.size(), dh->I_n, dh->I_c);
		timer.end();
		printf("\n%-25s: %-6.6fs\n", "Lightning Estimation", timer.get());
		
		timer.start();
		// Albedo estimation (GPU)
		cuda_based_albedo_estimation(cublas_handle, cusp_handle, d_s, d_rho, d_N, d_I, (int)imask.size(), dh->I_n, dh->I_c);
		timer.end();
		printf("%-25s: %-6.6fs\n", "Albedo Estimation", timer.get());

		timer.start();
		// Depth estimation (GPU)
		float error = cuda_based_depth_estimation(cublas_handle, cusp_handle, d_s, d_rho, d_N, d_I, d_xx, d_yy, d_dz, d_Dx_row_ptr, d_Dx_col_ind, d_Dx_val, G.first.n_row, G.first.n_col, G.first.n_nz, d_Dy_row_ptr, d_Dy_col_ind, d_Dy_val, G.second.n_row, G.second.n_col, G.second.n_nz, d_KT_row_ptr, d_KT_col_ind, d_KT_val, KT.n_row, KT.n_col, KT.n_nz, d_z0s, d_z, dh->K[0], dh->K[4], (int)imask.size(), dh->I_n, dh->I_c);
		timer.end();
		printf("%-25s: %-6.6fs\n", "Depth Estimation", timer.get());

		// Terminating conditions
		float rel_err = fabs(last_error - error) / fabs(error);
		if (error > last_error || rel_err < TOLERANCE || iteration > MAX_ITERATIONS) {
			stop_loop = true;
		}
		last_error = error;
		printf("\nIteration %02d summary\n", iteration);
		printf("%-25s: %-6.3f\n", "Error", error);
		printf("%-25s: %-6.3f\n", "Relative Error",rel_err);
		cudaFree(d_zx); CUDA_CHECK;
		cudaFree(d_zy); CUDA_CHECK;

		// Recalculate normals (GPU)
		d_zx = cuda_based_sparsemat_densevec_mul(cusp_handle, d_Dx_row_ptr, d_Dx_col_ind, d_Dx_val, G.first.n_row, G.first.n_col, G.first.n_nz, d_z);
		d_zy = cuda_based_sparsemat_densevec_mul(cusp_handle, d_Dy_row_ptr, d_Dy_col_ind, d_Dy_val, G.second.n_row, G.second.n_col, G.second.n_nz, d_z);
		cudaFree(d_dz); CUDA_CHECK;
		cudaFree(d_N); CUDA_CHECK;
		d_dz = NULL;
		d_N = cuda_based_normal_init(cublas_handle, d_z, d_zx, d_zy, d_xx, d_yy, (int)imask.size(), dh->K[0], dh->K[4], &d_dz);
		
		iteration++;

		// Visualizations
		float scale = 0.425f;
		cv::imshow("Normals-Initial", N_as_opencv_mat(d_init_N, imask, dh->I_h, dh->I_w, scale));
		cv::moveWindow("Normals-Initial", 10, 10);
		cv::imshow("Normals-Current-Iteration", N_as_opencv_mat(d_N, imask, dh->I_h, dh->I_w, scale));
		cv::moveWindow("Normals-Current-Iteration", (int)(30 + dh->I_h * scale), 10);
		cv::imshow("Albedo", rho_as_opencv_mat(d_rho, imask, dh->I_h, dh->I_w, dh->I_c, scale));
		cv::moveWindow("Albedo", (int)(30 + 2 * dh->I_h * scale),10);
		cv::waitKey(5);

		// Dump as MAT files
		WRITE_MAT_FROM_DEVICE(d_s, dh->I_n * dh->I_c * 4, "s.mat");
		WRITE_MAT_FROM_DEVICE(d_rho, imask.size() * dh->I_c, "rho.mat");
		WRITE_MAT_FROM_DEVICE(d_z, imask.size(), "z.mat");
		WRITE_MAT_FROM_DEVICE(d_N, imask.size() * 4, "N.mat");

	} while (!stop_loop);
	
	std::cout << "Done!" << std::endl;
	cv::waitKey(0);
	
	if (cusparseDestroy(cusp_handle) != CUSPARSE_STATUS_SUCCESS) {
		throw std::runtime_error("CUSPARSE Library release of resources failed");
	}
	if (cublasDestroy(cublas_handle) != CUBLAS_STATUS_SUCCESS) {
		throw std::runtime_error("CUBLAS Library release of resources failed");
	}

	dh->D.freeMemory();
	cudaFree(d_D_col_ind); CUDA_CHECK;
	cudaFree(d_D_row_ptr); CUDA_CHECK;
	cudaFree(d_D_val); CUDA_CHECK;
	cudaFree(d_Dx_col_ind); CUDA_CHECK;
	cudaFree(d_Dx_row_ptr); CUDA_CHECK;
	cudaFree(d_Dx_val); CUDA_CHECK;
	cudaFree(d_Dy_col_ind); CUDA_CHECK;
	cudaFree(d_Dy_row_ptr); CUDA_CHECK;
	cudaFree(d_Dy_val); CUDA_CHECK;
	cudaFree(d_mask); CUDA_CHECK;
	cudaFree(d_N); CUDA_CHECK;
	cudaFree(d_init_N); CUDA_CHECK;
	cudaFree(d_z); CUDA_CHECK;
	cudaFree(d_dz); CUDA_CHECK;
	cudaFree(d_z0s); CUDA_CHECK;
	cudaFree(d_masks); CUDA_CHECK;
	cudaFree(d_I); CUDA_CHECK;
	delete[] inpaint_mask;
	delete[] masks;
	delete[] inpaint_locations;
	delete[] zs;
	delete[] z_full;
}




