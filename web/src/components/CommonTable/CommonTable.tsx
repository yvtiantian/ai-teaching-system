'use client'

import React, { useRef, useState, useEffect, useCallback, useMemo } from 'react'
import { Table, Pagination } from 'antd'
import { InboxOutlined } from '@ant-design/icons'
import type { ColumnType, ColumnsType, TableProps } from 'antd/es/table'
import type { Key } from 'react'
import './CommonTable.css'

type SortOrder = 'ascend' | 'descend'

interface SortState<T> {
  columnKey?: Key
  order?: SortOrder
  compare?: (a: T, b: T, sortOrder?: SortOrder) => number
}

function getColumnCompare<T extends object>(
  columns: ColumnsType<T>,
  targetKey?: Key
): SortState<T>['compare'] {
  if (targetKey == null) return undefined

  for (const column of columns) {
    if ('children' in column && column.children) {
      const nestedCompare = getColumnCompare(column.children, targetKey)
      if (nestedCompare) return nestedCompare
      continue
    }

    const leafColumn = column as ColumnType<T>
    const columnIdentifier = leafColumn.key ?? leafColumn.dataIndex
    if (columnIdentifier !== targetKey) continue

    if (typeof leafColumn.sorter === 'function') {
      return leafColumn.sorter
    }

    if (leafColumn.sorter && typeof leafColumn.sorter === 'object' && 'compare' in leafColumn.sorter) {
      return leafColumn.sorter.compare
    }
  }

  return undefined
}

// 分页配置
export interface PaginationConfig {
  current: number
  pageSize: number
  total: number
  onChange?: (page: number, pageSize: number) => void
  showSizeChanger?: boolean
  pageSizeOptions?: string[]
}

// 选择行配置
export interface RowSelectionConfig<T> {
  type: 'checkbox' | 'radio'
  selectedRowKeys: Key[]
  onChange: (selectedRowKeys: Key[]) => void
  getCheckboxProps?: (record: T) => { disabled?: boolean }
}

// 空状态配置
export interface EmptyConfig {
  title?: string
  description?: string
  icon?: React.ReactNode
}

// 主组件 Props
export interface CommonTableProps<T extends object> {
  // 核心属性
  columns: ColumnsType<T>
  dataSource: T[]
  rowKey: string | ((record: T) => string)
  loading?: boolean

  // 分页配置 (false 或不传则禁用)
  pagination?: PaginationConfig | false
  paginationMode?: 'client' | 'server'

  // 选择行配置 (false 或不传则禁用)
  rowSelection?: RowSelectionConfig<T> | false

  // 空状态定制
  empty?: EmptyConfig

  // 其他配置
  scroll?: { x?: number | string }
  expandable?: TableProps<T>['expandable']
  className?: string
}

// 默认分页选项
const DEFAULT_PAGE_SIZE_OPTIONS = ['10', '20', '50', '100']

// 分页区域高度（包含 padding）
const PAGINATION_HEIGHT = 56

function CommonTable<T extends object>({
  columns,
  dataSource,
  rowKey,
  loading = false,
  pagination,
  paginationMode = 'client',
  rowSelection,
  empty,
  scroll,
  expandable,
  className = '',
}: CommonTableProps<T>) {
  const containerRef = useRef<HTMLDivElement>(null)
  const [tableScrollY, setTableScrollY] = useState<number | undefined>(undefined)
  const [sortState, setSortState] = useState<SortState<T>>({})
  const paginationConfig = pagination || undefined

  // 判断是否为空数据
  const isEmpty = dataSource.length === 0

  // 判断是否显示分页：总数大于 0 时显示分页
  const shouldShowPagination = paginationConfig
    ? (paginationConfig.total > 0 || !isEmpty)
    : false

  const sortedData = useMemo(() => {
    if (paginationMode !== 'client' || !sortState.order || !sortState.compare) {
      return dataSource
    }

    const result = [...dataSource]
    result.sort((a, b) => {
      const compareResult = sortState.compare?.(a, b, sortState.order) ?? 0
      return sortState.order === 'descend' ? -compareResult : compareResult
    })
    return result
  }, [dataSource, paginationMode, sortState])

  // 计算当前页显示的数据。server 模式不做前端切片。
  const paginatedData = paginationConfig && paginationMode === 'client'
    ? sortedData.slice(
      (paginationConfig.current - 1) * paginationConfig.pageSize,
      paginationConfig.current * paginationConfig.pageSize
    )
    : sortedData

  const controlledColumns = useMemo(() => {
    const applySortOrder = (tableColumns: ColumnsType<T>): ColumnsType<T> => tableColumns.map((column) => {
      if ('children' in column && column.children) {
        return {
          ...column,
          children: applySortOrder(column.children),
        }
      }

      const leafColumn = column as ColumnType<T>
      const columnIdentifier = leafColumn.key ?? leafColumn.dataIndex
      if (!leafColumn.sorter) return leafColumn

      return {
        ...leafColumn,
        sortOrder: columnIdentifier === sortState.columnKey ? sortState.order : null,
      }
    })

    return applySortOrder(columns)
  }, [columns, sortState.columnKey, sortState.order])

  // 计算表格可用高度
  const calculateTableHeight = useCallback(() => {
    if (!containerRef.current) return

    const containerHeight = containerRef.current.clientHeight
    // 只有在实际显示分页时才减去分页区域高度
    const paginationSpace = shouldShowPagination ? PAGINATION_HEIGHT : 0
    // 表头高度约 55px
    const headerHeight = 55
    // 可用于表格内容的高度
    const availableHeight = containerHeight - paginationSpace - headerHeight

    // 简化策略：总是设置 scroll.y，让 Ant Design 自己处理对齐
    // Ant Design 会根据实际内容决定是否显示滚动条
    if (availableHeight > 100) {
      setTableScrollY(availableHeight)
    }
  }, [shouldShowPagination])

  // 监听容器大小变化
  useEffect(() => {
    calculateTableHeight()

    const resizeObserver = new ResizeObserver(() => {
      calculateTableHeight()
    })

    if (containerRef.current) {
      resizeObserver.observe(containerRef.current)
    }

    return () => {
      resizeObserver.disconnect()
    }
  }, [calculateTableHeight])

  // 构建 Table 的 rowSelection 配置
  const tableRowSelection = rowSelection
    ? {
      type: rowSelection.type,
      selectedRowKeys: rowSelection.selectedRowKeys,
      onChange: (selectedKeys: Key[]) => {
        rowSelection.onChange(selectedKeys)
      },
      getCheckboxProps: rowSelection.getCheckboxProps,
    }
    : undefined

  // 构建滚动配置 - 只有需要时才设置 y
  const tableScroll = {
    x: scroll?.x,
    y: tableScrollY,
  }

  return (
    <div ref={containerRef} className={`common-table-wrapper ${isEmpty ? 'is-empty' : ''} ${className}`}>
      <div className="common-table-content">
        <Table<T>
          columns={controlledColumns}
          dataSource={paginatedData}
          rowKey={rowKey}
          loading={loading}
          pagination={false}
          rowSelection={tableRowSelection}
          scroll={tableScroll}
          expandable={expandable}
          onChange={(_, __, sorter) => {
            if (Array.isArray(sorter)) {
              const firstSorter = sorter.find((item) => item.order)
              setSortState({
                columnKey: firstSorter?.columnKey,
                order: firstSorter?.order ?? undefined,
                compare: getColumnCompare(columns, firstSorter?.columnKey),
              })
              return
            }

            setSortState({
              columnKey: sorter.columnKey,
              order: sorter.order ?? undefined,
              compare: getColumnCompare(columns, sorter.columnKey),
            })
          }}
          locale={{
            emptyText: (
              <div className="common-table-empty">
                {empty?.icon || <InboxOutlined className="common-table-empty-icon" />}
                <div className="common-table-empty-title">{empty?.title || '暂无数据'}</div>
              </div>
            ),
          }}
        />
      </div>

      {shouldShowPagination && paginationConfig && (
        <div className="common-table-pagination">
          <Pagination
            current={paginationConfig.current}
            pageSize={paginationConfig.pageSize}
            total={paginationConfig.total}
            onChange={paginationConfig.onChange}
            showSizeChanger={paginationConfig.showSizeChanger ?? true}
            pageSizeOptions={paginationConfig.pageSizeOptions ?? DEFAULT_PAGE_SIZE_OPTIONS}
            showTotal={(total) => `共 ${total} 条`}
          />
        </div>
      )}
    </div>
  )
}

export default CommonTable
